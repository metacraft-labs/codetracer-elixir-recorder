ExUnit.start()

defmodule CodetracerBeamRecorder.StressEventVolumeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M17 verification: drives the five M17 stress fixtures
  (`stress_calls`, `stress_processes`, `stress_mailboxes`,
  `stress_terms`, `stress_crashes`) through the real recorder against
  real BEAM processes and asserts:

    * the recorder process exits 0 for every fixture
    * each bundle is well-formed and round-trips through the same
      `read-bundle-summary` reader path the M5/M6/M7 tests use
    * the runtime session finalized cleanly (`trace_delivered`)
    * memory stays bounded — peak RSS while running each fixture
      stays under 2 GiB. RSS is sampled by polling /proc/<pid>/status
      every 50 ms; on platforms without /proc the test asserts only
      that the recorder produced a well-formed bundle (the well-
      formedness oracle catches unbounded growth indirectly because
      the OS would have OOM-killed the recorder).

  The stress fixtures are intentionally call-heavy / process-heavy /
  mailbox-heavy / term-heavy / crash-heavy rather than fast: the goal
  is "no silent corruption / no unbounded memory", not "low overhead".
  """

  @repo_root Path.expand("../..", __DIR__)
  @erlang_fixtures Path.join(@repo_root, "test-programs/erlang")

  # 2 GiB hard ceiling. Under normal tracing the recorder runs well
  # below this; the ceiling is the "did the recorder leak unboundedly"
  # tripwire for the 100k-call fixture.
  @rss_ceiling_bytes 2 * 1024 * 1024 * 1024

  test "stress_beam_recorder_event_volume_real_targets" do
    fixtures = [
      %{
        name: "stress_calls",
        module: "stress_calls",
        timeout_ms: 600_000
      },
      %{
        name: "stress_processes",
        module: "stress_processes",
        timeout_ms: 300_000
      },
      %{
        name: "stress_mailboxes",
        module: "stress_mailboxes",
        timeout_ms: 300_000
      },
      %{
        name: "stress_terms",
        module: "stress_terms",
        timeout_ms: 300_000
      },
      %{
        name: "stress_crashes",
        module: "stress_crashes",
        timeout_ms: 300_000
      }
    ]

    for fixture <- fixtures do
      result = run_stress_fixture!(fixture)

      assert result.exit_code == 0,
             """
             stress fixture #{fixture.name} recorder exited #{result.exit_code}

             #{result.output}
             """

      assert result.peak_rss_bytes <= @rss_ceiling_bytes,
             """
             stress fixture #{fixture.name} peak RSS #{result.peak_rss_bytes} bytes
             exceeded ceiling #{@rss_ceiling_bytes} (2 GiB).
             This indicates unbounded memory growth in the recorder
             writer — not a perf regression but a correctness defect.
             """

      assert result.summary["status"] == "ok",
             "stress fixture #{fixture.name} bundle did not load cleanly"

      assert result.summary["runtime_session_delivered"] == true,
             "stress fixture #{fixture.name} did not finalize runtime session"

      assert result.summary["sidecar_trace_delivered"] == true,
             "stress fixture #{fixture.name} sidecar missing trace_delivered"

      assert result.summary["thread_start_count_root"] >= 1
      assert result.summary["thread_exit_count_root"] >= 1

      total_sidecar_events =
        (result.summary["sidecar_call_count"] || 0) +
          (result.summary["sidecar_return_count"] || 0) +
          (result.summary["process_spawn_count"] || 0) +
          (result.summary["process_exit_count"] || 0) +
          (result.summary["send_event_count"] || 0) +
          (result.summary["receive_event_count"] || 0)

      assert total_sidecar_events > 0,
             "stress fixture #{fixture.name} produced an empty sidecar"
    end
  end

  defp run_stress_fixture!(fixture) do
    out_dir = tmp_dir!("m17-#{fixture.name}-out")
    ebin_dir = tmp_dir!("m17-#{fixture.name}-ebin")
    compile_erlang_fixture!(fixture.name, ebin_dir)

    args =
      [
        "record",
        "--out-dir",
        out_dir,
        "--",
        "erl",
        "-noshell",
        "-pa",
        ebin_dir,
        "-s",
        fixture.module,
        "main",
        "-s",
        "init",
        "stop"
      ]

    {output, exit_code, peak_rss_bytes} =
      run_with_rss_sampler(recorder_binary!(), args, fixture.timeout_ms)

    summary =
      if exit_code == 0 do
        read_bundle_summary!(out_dir)
      else
        %{}
      end

    %{
      output: output,
      exit_code: exit_code,
      peak_rss_bytes: peak_rss_bytes,
      summary: summary
    }
  end

  defp run_with_rss_sampler(binary, args, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, binary},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args}
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    sampler = spawn_link(fn -> rss_sample_loop(os_pid, 0, self()) end)
    send(sampler, {:owner, self()})

    {output, exit_code} = drain_port(port, "", timeout_ms)
    send(sampler, :stop)

    peak_rss_bytes =
      receive do
        {:peak_rss_bytes, value} -> value
      after
        5_000 -> 0
      end

    {output, exit_code, peak_rss_bytes}
  end

  defp drain_port(port, acc, timeout_ms) do
    receive do
      {^port, {:data, data}} -> drain_port(port, acc <> data, timeout_ms)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      timeout_ms ->
        Port.close(port)
        {acc <> "\n[timeout after #{timeout_ms}ms]\n", 124}
    end
  end

  defp rss_sample_loop(os_pid, peak, owner) do
    receive do
      :stop ->
        if owner, do: send(owner, {:peak_rss_bytes, peak})
        :ok

      {:owner, new_owner} ->
        rss_sample_loop(os_pid, peak, new_owner)
    after
      50 ->
        new_peak = max(peak, sample_rss_bytes(os_pid))
        rss_sample_loop(os_pid, new_peak, owner)
    end
  end

  defp sample_rss_bytes(os_pid) do
    case File.read("/proc/#{os_pid}/status") do
      {:ok, contents} ->
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/, contents, capture: :all_but_first) do
          [kb_str] -> String.to_integer(kb_str) * 1024
          _ -> 0
        end

      {:error, _} ->
        # /proc not available (e.g. macOS) — return 0 so the ceiling
        # comparison degenerates to "the recorder did not OOM-kill".
        0
    end
  end

  defp compile_erlang_fixture!(name, ebin_dir) do
    src = Path.join([@erlang_fixtures, name, "src", "#{name}.erl"])

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, src], stderr_to_stdout: true)

    assert status == 0, "erlc #{src} failed: #{output}"
  end

  defp recorder_binary! do
    debug = Path.join([@repo_root, "target", "debug", "codetracer-beam-recorder"])
    release = Path.join([@repo_root, "target", "release", "codetracer-beam-recorder"])

    cond do
      override = System.get_env("CODETRACER_BEAM_RECORDER_BIN") ->
        File.exists?(override) ||
          flunk("CODETRACER_BEAM_RECORDER_BIN=#{override} does not exist")

        override

      File.exists?(debug) ->
        debug

      File.exists?(release) ->
        release

      true ->
        flunk("codetracer-beam-recorder binary not built; run cargo build --locked")
    end
  end

  defp read_bundle_summary!(out_dir) do
    {output, status} =
      System.cmd(
        recorder_binary!(),
        ["read-bundle-summary", "--bundle", out_dir],
        stderr_to_stdout: true
      )

    assert status == 0,
           "read-bundle-summary failed for #{out_dir} with status #{status}\n\n#{output}"

    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> decode_json!()
  end

  # Tiny JSON decoder shared with otp_fixture_matrix_test.exs / native_tracer_parity_test.exs.
  defp decode_json!(input) do
    {value, _rest} = parse_value(skip_ws(input))
    value
  end

  defp parse_value(<<?", _rest::binary>> = input), do: parse_string(input)
  defp parse_value(<<?{, _::binary>> = input), do: parse_object(input)
  defp parse_value(<<?[, _::binary>> = input), do: parse_array(input)
  defp parse_value(<<"true", rest::binary>>), do: {true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {false, rest}
  defp parse_value(<<"null", rest::binary>>), do: {nil, rest}

  defp parse_value(<<char::utf8, _::binary>> = input)
       when char in ?0..?9 or char == ?- do
    parse_number(input, "")
  end

  defp parse_object(<<?{, rest::binary>>) do
    case skip_ws(rest) do
      <<?}, after_brace::binary>> -> {%{}, after_brace}
      remainder -> parse_object_entries(remainder, %{})
    end
  end

  defp parse_object_entries(input, acc) do
    {key, after_key} = parse_string(skip_ws(input))
    <<?:, after_colon::binary>> = skip_ws(after_key)
    {value, after_value} = parse_value(skip_ws(after_colon))
    acc = Map.put(acc, key, value)

    case skip_ws(after_value) do
      <<?,, rest::binary>> -> parse_object_entries(skip_ws(rest), acc)
      <<?}, rest::binary>> -> {acc, rest}
    end
  end

  defp parse_array(<<?[, rest::binary>>) do
    case skip_ws(rest) do
      <<?], after_bracket::binary>> -> {[], after_bracket}
      remainder -> parse_array_entries(remainder, [])
    end
  end

  defp parse_array_entries(input, acc) do
    {value, after_value} = parse_value(skip_ws(input))
    acc = [value | acc]

    case skip_ws(after_value) do
      <<?,, rest::binary>> -> parse_array_entries(skip_ws(rest), acc)
      <<?], rest::binary>> -> {Enum.reverse(acc), rest}
    end
  end

  defp parse_string(<<?", rest::binary>>), do: parse_string_chars(rest, "")
  defp parse_string_chars(<<?", rest::binary>>, acc), do: {acc, rest}
  defp parse_string_chars(<<?\\, ?", rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\"")
  defp parse_string_chars(<<?\\, ?\\, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\\")
  defp parse_string_chars(<<?\\, ?n, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\n")
  defp parse_string_chars(<<?\\, ?t, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\t")
  defp parse_string_chars(<<?\\, ?r, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "\r")
  defp parse_string_chars(<<?\\, ?/, rest::binary>>, acc), do: parse_string_chars(rest, acc <> "/")

  defp parse_string_chars(<<char::utf8, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> <<char::utf8>>)

  defp parse_number(<<char::utf8, rest::binary>>, acc)
       when char in ?0..?9 or char in [?-, ?+, ?., ?e, ?E] do
    parse_number(rest, acc <> <<char::utf8>>)
  end

  defp parse_number(rest, acc) do
    cond do
      String.contains?(acc, ".") or String.contains?(acc, "e") or String.contains?(acc, "E") ->
        {String.to_float(acc), rest}

      true ->
        {String.to_integer(acc), rest}
    end
  end

  defp skip_ws(<<char::utf8, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r],
    do: skip_ws(rest)

  defp skip_ws(input), do: input

  defp tmp_dir!(label) do
    nonce = System.unique_integer([:positive])
    pid = System.system_time(:nanosecond)
    path = Path.join(System.tmp_dir!(), "codetracer-beam-recorder-#{label}-#{pid}-#{nonce}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
