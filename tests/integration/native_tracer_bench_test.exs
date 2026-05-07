ExUnit.start()

defmodule CodetracerBeamRecorder.NativeTracerBenchTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M16 benchmark verification: runs the three M16 benchmark fixtures
  (call-heavy, process-heavy, message-heavy) through both the
  `process` and `native` tracer backends and records wall-clock results
  to `benches/native_tracer_baseline.md`. The test asserts that *all
  six* runs completed without recorder errors and that the baseline
  file was written; it deliberately does *not* assert on relative
  performance numbers — the goal in M16 is to capture a baseline,
  not to optimize.
  """

  @repo_root Path.expand("../..", __DIR__)
  @bench_fixture Path.join(@repo_root, "test-programs/erlang/native_tracer_bench")
  @baseline_path Path.join(@repo_root, "benches/native_tracer_baseline.md")
  @fixtures [
    {"call_heavy", "call-heavy (1000-iter recursive sum)"},
    {"process_heavy", "process-heavy (200 short-lived spawns)"},
    {"message_heavy", "message-heavy (1000 ping messages)"}
  ]
  @backends ["process", "native"]

  test "bench_native_tracer_overhead_real_fixtures" do
    ebin_dir = tmp_dir!("bench-ebin")
    compile_bench_fixture!(ebin_dir)

    File.mkdir_p!(Path.dirname(@baseline_path))

    rows =
      for {entry, label} <- @fixtures, backend <- @backends do
        out_dir = tmp_dir!("bench-#{entry}-#{backend}")
        {wall_us, status, output} = time_record!(out_dir, ebin_dir, entry, backend)

        assert status == 0, """
        bench fixture #{entry} under #{backend} backend exited #{status}

        #{output}
        """

        sidecar_path = Path.join(out_dir, "runtime_session.jsonl")
        assert File.exists?(sidecar_path), "sidecar must exist for #{entry}/#{backend}"

        sidecar_text = File.read!(sidecar_path)
        event_count = sidecar_event_count(sidecar_text)

        delivered? = String.contains?(sidecar_text, "\"event\":\"trace_delivered\"")

        assert delivered?, "trace_delivered must appear in #{entry}/#{backend} sidecar"

        sidecar_size = byte_size(sidecar_text)

        %{
          fixture: entry,
          label: label,
          backend: backend,
          wall_us: wall_us,
          event_count: event_count,
          sidecar_bytes: sidecar_size
        }
      end

    write_baseline!(rows)

    assert File.exists?(@baseline_path),
           "benchmark baseline must be written to #{@baseline_path}"

    # Sanity check: the baseline file must mention every (fixture, backend)
    # pairing.
    body = File.read!(@baseline_path)

    for {entry, _label} <- @fixtures, backend <- @backends do
      assert body =~ entry,
             "baseline must record #{entry}, missing for #{backend}"

      assert body =~ backend,
             "baseline must record #{backend}, missing for #{entry}"
    end
  end

  defp time_record!(out_dir, ebin_dir, entry, backend) do
    args = [
      "record",
      "--out-dir",
      out_dir,
      "--tracer-backend",
      backend,
      "--",
      "erl",
      "-noshell",
      "-pa",
      ebin_dir,
      "-s",
      "native_tracer_bench",
      entry,
      "-s",
      "init",
      "stop"
    ]

    started = System.monotonic_time()
    {output, status} = System.cmd(recorder_binary!(), args, stderr_to_stdout: true)
    finished = System.monotonic_time()
    wall_us = System.convert_time_unit(finished - started, :native, :microsecond)
    {wall_us, status, output}
  end

  defp sidecar_event_count(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.count(fn line ->
      String.contains?(line, "\"event\":") and
        not String.contains?(line, "\"event\":\"trace_delivered\"") and
        not String.contains?(line, "\"event\":\"manifest_loaded\"")
    end)
  end

  defp write_baseline!(rows) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    header = """
    # M16 Native Tracer Benchmark Baseline

    Captured: #{timestamp}

    Recorder: codetracer-beam-recorder, --tracer-backend {process|native}.
    Workloads exercise the three M16 pressure axes against real BEAM
    targets via `erl -s native_tracer_bench <entry>`.

    | fixture | backend | wall_us | event_count | sidecar_bytes |
    | --- | --- | ---: | ---: | ---: |
    """

    body =
      rows
      |> Enum.map(fn r ->
        "| #{r.fixture} | #{r.backend} | #{r.wall_us} | #{r.event_count} | #{r.sidecar_bytes} |"
      end)
      |> Enum.join("\n")

    notes = """


    Notes:
    - Wall-clock time is for the *whole record + target run*, including
      BEAM boot, instrumentation, target execution, and shutdown barrier.
      Subtract the BEAM-boot baseline (~200ms cold) when comparing
      backends.
    - The native backend currently writes events to the same JSONL
      sidecar as the process backend; relative performance reflects the
      cost of the dedicated tracer process + atomic sequence counter
      versus the gen_server tracer. A real `erl_tracer` NIF (M17) is
      expected to widen the gap.
    - Event_count counts trace events (excluding the trace_delivered
      summary line and any manifest_loaded headers).
    - Run `just test-integration` (or `elixir tests/integration/native_tracer_bench_test.exs`)
      to refresh this baseline.
    """

    File.write!(@baseline_path, [header, body, notes])
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

  defp compile_bench_fixture!(ebin_dir) do
    File.mkdir_p!(ebin_dir)
    source = Path.join(@bench_fixture, "src/native_tracer_bench.erl")

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, source], stderr_to_stdout: true)

    assert status == 0, "erlc #{source} failed: #{output}"
  end
end
