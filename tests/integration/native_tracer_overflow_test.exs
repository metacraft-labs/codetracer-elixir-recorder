ExUnit.start()

defmodule CodetracerBeamRecorder.NativeTracerOverflowTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M16 verification: forces queue pressure on the native tracer with a
  real BEAM target (the spawn_messages flood fixture) while configuring
  a tiny `--tracer-queue-limit` and the `drop` overflow policy. Verifies
  that the overflow path is taken — i.e. the recorder writes a
  `recorder_overflow` diagnostic event into the sidecar — rather than
  silently dropping events.

  Silent loss is a release blocker; this test exists to fail loudly if
  the overflow path stops emitting diagnostics.
  """

  @repo_root Path.expand("../..", __DIR__)
  @erlang_fixture Path.join(@repo_root, "test-programs/erlang/spawn_messages")

  test "e2e_native_tracer_overflow_diagnostic" do
    out_dir = tmp_dir!("native-overflow")
    ebin_dir = tmp_dir!("native-overflow-ebin")
    compile_erlang_fixture!(ebin_dir)

    # Force aggressive queue pressure: a *very* small queue limit + the
    # drop policy. The flood fixture sends 64 messages; with a limit of
    # 1, message_queue_len > limit will fire on essentially every
    # incoming trace event the moment two arrive in the tracer mailbox.
    {output, status} =
      System.cmd(
        recorder_binary!(),
        [
          "record",
          "--out-dir",
          out_dir,
          "--tracer-backend",
          "native",
          "--tracer-queue-limit",
          "1",
          "--tracer-overflow-policy",
          "drop",
          "--",
          "erl",
          "-noshell",
          "-pa",
          ebin_dir,
          "-s",
          "spawn_messages",
          "flood",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_fixture,
        stderr_to_stdout: true
      )

    # The recording must complete (the producer doesn't crash on
    # overflow under the drop policy), but the recorder must surface
    # the diagnostic.
    assert status == 0, """
    overflow recording (drop policy) exited #{status}

    #{output}
    """

    sidecar = Path.join(out_dir, "runtime_session.jsonl")
    assert File.exists?(sidecar), "expected runtime_session.jsonl at #{sidecar}"
    text = File.read!(sidecar)

    # Hard requirement: at least one recorder_overflow diagnostic line
    # must be present. Silent loss == test failure.
    assert String.contains?(text, "\"event\":\"recorder_overflow\""),
           """
           native overflow path must emit a recorder_overflow diagnostic event;
           with a queue_limit of 1 the flood fixture's 64 messages cannot fit.
           Silent event loss without a diagnostic is a release blocker.
           """

    # The trace_delivered summary must agree: dropped_event_count > 0
    # and overflow_fired > 0. Without these counters the user has no
    # way to see how much data was lost.
    delivered_line =
      text
      |> String.split("\n", trim: true)
      |> Enum.find(fn line -> String.contains?(line, "\"event\":\"trace_delivered\"") end)

    assert delivered_line, "native sidecar must include a trace_delivered summary"

    [dropped] = Regex.run(~r/"dropped_event_count":(\d+)/, delivered_line, capture: :all_but_first)
    [fired] = Regex.run(~r/"overflow_fired":(\d+)/, delivered_line, capture: :all_but_first)
    [policy] = Regex.run(~r/"overflow_policy":"(\w+)"/, delivered_line, capture: :all_but_first)
    [limit] = Regex.run(~r/"queue_limit":(\d+)/, delivered_line, capture: :all_but_first)

    assert policy == "drop",
           "trace_delivered must record that the drop policy was active; got #{policy}"

    assert String.to_integer(limit) == 1,
           "trace_delivered must record the configured queue_limit; got #{limit}"

    assert String.to_integer(dropped) > 0,
           "drop policy under aggressive pressure must report >0 dropped events; got #{dropped}"

    assert String.to_integer(fired) > 0,
           "drop policy under aggressive pressure must record >0 overflow_fired events; got #{fired}"

    # Block policy must produce ZERO drops under the same workload.
    block_out = tmp_dir!("native-overflow-block")

    {block_output, block_status} =
      System.cmd(
        recorder_binary!(),
        [
          "record",
          "--out-dir",
          block_out,
          "--tracer-backend",
          "native",
          "--tracer-queue-limit",
          "1",
          "--tracer-overflow-policy",
          "block",
          "--",
          "erl",
          "-noshell",
          "-pa",
          ebin_dir,
          "-s",
          "spawn_messages",
          "flood",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_fixture,
        stderr_to_stdout: true
      )

    assert block_status == 0, """
    block-policy recording must succeed even under pressure; got #{block_status}

    #{block_output}
    """

    block_text = block_out |> Path.join("runtime_session.jsonl") |> File.read!()

    block_delivered =
      block_text
      |> String.split("\n", trim: true)
      |> Enum.find(fn line -> String.contains?(line, "\"event\":\"trace_delivered\"") end)

    [block_dropped] =
      Regex.run(~r/"dropped_event_count":(\d+)/, block_delivered, capture: :all_but_first)

    assert String.to_integer(block_dropped) == 0,
           "block policy must guarantee zero dropped events; got #{block_dropped}"
  end

  defp recorder_binary! do
    case System.get_env("CODETRACER_BEAM_RECORDER_BIN") do
      nil ->
        debug = Path.join([@repo_root, "target", "debug", "codetracer-beam-recorder"])
        release = Path.join([@repo_root, "target", "release", "codetracer-beam-recorder"])

        cond do
          File.exists?(debug) -> debug
          File.exists?(release) -> release
          true ->
            flunk("""
            codetracer-beam-recorder binary not found in target/debug or target/release.
            Build it via `cargo build --locked` first, or set CODETRACER_BEAM_RECORDER_BIN.
            """)
        end

      override ->
        File.exists?(override) ||
          flunk("CODETRACER_BEAM_RECORDER_BIN=#{override} does not exist")

        override
    end
  end

  defp tmp_dir!(label) do
    nonce = System.unique_integer([:positive])
    pid = System.system_time(:nanosecond)

    path =
      Path.join(
        System.tmp_dir!(),
        "codetracer-beam-recorder-m16-#{label}-#{pid}-#{nonce}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp compile_erlang_fixture!(ebin_dir) do
    File.mkdir_p!(ebin_dir)
    source = Path.join(@erlang_fixture, "src/spawn_messages.erl")

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, source], stderr_to_stdout: true)

    assert status == 0, "erlc #{source} failed: #{output}"
  end
end
