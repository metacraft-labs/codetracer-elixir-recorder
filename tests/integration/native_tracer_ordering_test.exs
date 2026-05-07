ExUnit.start()

defmodule CodetracerBeamRecorder.NativeTracerOrderingTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M16 verification: stress-records many real BEAM processes through the
  native tracer and verifies the per-event sequence numbers stamped by
  `codetracer_native_tracer:next_seq/1` form a strictly increasing,
  contiguous sequence in the order the events appear in the sidecar.

  The native queue's atomic counter is the deterministic ordering oracle:
  events must arrive in CTFS in sequence-number order regardless of which
  process produced them. The fixture spawns multiple producer processes
  that send messages back to the root, which then writes each receive
  through the same tracer process.
  """

  @repo_root Path.expand("../..", __DIR__)
  @erlang_fixture Path.join(@repo_root, "test-programs/erlang/spawn_messages")

  test "e2e_native_tracer_ordering_stress" do
    out_dir = tmp_dir!("native-ordering")
    ebin_dir = tmp_dir!("native-ordering-ebin")
    compile_erlang_fixture!(ebin_dir)

    {output, status} =
      System.cmd(
        recorder_binary!(),
        [
          "record",
          "--out-dir",
          out_dir,
          "--tracer-backend",
          "native",
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

    assert status == 0, """
    spawn_messages flood under native backend failed with status #{status}

    #{output}
    """

    sidecar = Path.join(out_dir, "runtime_session.jsonl")
    text = File.read!(sidecar)

    sequences =
      text
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/"sequence":(\d+)/, line, capture: :all_but_first) do
          [seq] -> [String.to_integer(seq)]
          _ -> []
        end
      end)

    assert length(sequences) >= 64,
           "expected >=64 sequenced events from the flood fixture, got #{length(sequences)}"

    # Strictly increasing sequence numbers.
    sequences
    |> Enum.with_index()
    |> Enum.reduce(0, fn {seq, idx}, prev ->
      assert seq > prev,
             "sequence numbers must be strictly increasing; idx=#{idx} prev=#{prev} seq=#{seq}"

      seq
    end)

    # Contiguous (no gaps): the atomic counter is the only writer of
    # sequence numbers, so the sidecar must contain every sequence number
    # from 1 to N without holes. (Drops would create gaps; the block
    # policy guarantees no drops in this run.)
    expected = Enum.to_list(1..List.last(sequences))

    assert sequences == expected,
           "native sequence stream must be contiguous 1..N; first 20 sequences=#{inspect(Enum.take(sequences, 20))}"

    # Spawned-process events must land in the same monotonic stream as
    # root-process events: spot-check that we have events for at least
    # two distinct thread_ids.
    thread_ids =
      text
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/"thread_id":(\d+)/, line, capture: :all_but_first) do
          [tid] -> [String.to_integer(tid)]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert length(thread_ids) >= 2,
           "expected at least two distinct thread_ids in the native sidecar (root + spawned), got #{inspect(thread_ids)}"

    # The trace_delivered summary must record event_count matching the
    # last sequence number.
    delivered_line =
      text
      |> String.split("\n", trim: true)
      |> Enum.find(fn line -> String.contains?(line, "\"event\":\"trace_delivered\"") end)

    assert delivered_line, "native sidecar must include a trace_delivered summary"
    [event_count] = Regex.run(~r/"event_count":(\d+)/, delivered_line, capture: :all_but_first)
    last_seq = List.last(sequences)

    assert String.to_integer(event_count) == last_seq,
           "trace_delivered event_count must equal the last sequence number; event_count=#{event_count} last_seq=#{last_seq}"

    [overflow_count] =
      Regex.run(~r/"dropped_event_count":(\d+)/, delivered_line, capture: :all_but_first)

    assert String.to_integer(overflow_count) == 0,
           "block policy must not drop events under stress; dropped=#{overflow_count}"
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
