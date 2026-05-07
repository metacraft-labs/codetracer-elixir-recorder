ExUnit.start()

defmodule CodetracerBeamRecorder.OtpFixtureMatrixTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M17 verification: drives a matrix of real OTP fixtures through the
  recorder and asserts each bundle round-trips through the same
  `read-bundle-summary` reader path that runtime_session_test.exs and
  native_tracer_parity_test.exs use. Each fixture corresponds to one
  OTP construct (GenServer, Supervisor, Task, Agent, ETS, Application
  startup/shutdown). The assertion contract is intentionally per-fixture
  so a regression in one OTP behaviour fails loudly without masking the
  others.

  Real-target invariants enforced for every fixture:
    * recorder process exits 0
    * `read-bundle-summary` reports the bundle is well-formed
    * the sidecar finalized through `trace_delivered`
    * the recorded `runtime_session.jsonl` was non-empty (>0 sidecar
      events) — i.e. the recorder actually traced the workload
    * the per-fixture event-class oracle below holds
  """

  @repo_root Path.expand("../..", __DIR__)
  @fixtures_root Path.join(@repo_root, "test-programs/elixir")

  test "e2e_otp_fixture_matrix_real_trace" do
    fixtures = [
      %{
        name: "otp_genserver",
        eval: "OtpGenServer.main()",
        # GenServer.cast/call traffic must show up as send/receive pairs
        # and the recorder must observe child process spawn + exit for
        # the GenServer.
        oracle: fn s ->
          assert s["target_exit_code"] == 0
          assert s["process_spawn_count"] >= 1, "expected GenServer spawn event"
          assert s["process_exit_count"] >= 1, "expected GenServer exit event"
          assert s["send_event_count"] >= 1, "expected GenServer send traffic"
          assert s["receive_event_count"] >= 1, "expected GenServer receive traffic"
        end
      },
      %{
        name: "otp_supervisor",
        eval: "OtpSupervisor.main()",
        # A real Supervisor + 2 children = at least 3 spawn events.
        oracle: fn s ->
          assert s["target_exit_code"] == 0
          assert s["process_spawn_count"] >= 3,
                 "expected supervisor + >=2 children, got spawn_count=#{s["process_spawn_count"]}"
          assert s["send_event_count"] >= 1
        end
      },
      %{
        name: "otp_task",
        eval: "OtpTask.main()",
        # Task.async + Task.async_stream over 4 items = >=4 spawn events.
        oracle: fn s ->
          assert s["target_exit_code"] == 0
          assert s["process_spawn_count"] >= 4,
                 "expected >=4 task spawns, got #{s["process_spawn_count"]}"
        end
      },
      %{
        name: "otp_agent",
        eval: "OtpAgent.main()",
        # Agent is a GenServer underneath: same shape as otp_genserver.
        oracle: fn s ->
          assert s["target_exit_code"] == 0
          assert s["process_spawn_count"] >= 1
          assert s["process_exit_count"] >= 1
        end
      },
      %{
        name: "otp_ets",
        eval: "OtpEts.main()",
        # ETS calls run in the caller process — no spawned children
        # expected, but the runtime session must still have flushed
        # cleanly through trace_delivered.
        oracle: fn s ->
          assert s["target_exit_code"] == 0
          assert s["sidecar_trace_delivered"] == true
          assert s["runtime_session_delivered"] == true
        end
      },
      %{
        name: "otp_application",
        eval: "OtpApplication.main()",
        # Application startup runs `application_controller` -> `start/2`
        # before the recorder enables process tracing on the root, so
        # spawn events for the supervisor + worker are not necessarily
        # observed under the current root-trace setup. The fixture must,
        # however, still produce send/receive traffic from the
        # Application.ensure_all_started + GenServer.call exchange and
        # finalize cleanly — that is the actual M17 contract for the
        # Application-startup-and-shutdown deliverable. (Pre-tracing
        # spawn capture is M16-followup work.)
        oracle: fn s ->
          assert s["target_exit_code"] == 0
          assert s["send_event_count"] >= 1,
                 "expected Application.ensure_all_started + GenServer.call traffic, got 0 send events"

          assert s["receive_event_count"] >= 1,
                 "expected GenServer.call reply traffic, got 0 receive events"
        end
      }
    ]

    for fixture <- fixtures do
      summary = run_fixture!(fixture.name, fixture.eval)

      assert summary["status"] == "ok",
             "fixture #{fixture.name} read-bundle-summary status: #{inspect(summary["status"])}"

      assert summary["runtime_session_delivered"] == true,
             "fixture #{fixture.name} did not finalize runtime session"

      assert summary["sidecar_trace_delivered"] == true,
             "fixture #{fixture.name} sidecar missing trace_delivered marker"

      assert summary["thread_start_count_root"] >= 1
      assert summary["thread_exit_count_root"] >= 1

      total_sidecar_events =
        (summary["sidecar_call_count"] || 0) +
          (summary["sidecar_return_count"] || 0) +
          (summary["process_spawn_count"] || 0) +
          (summary["process_exit_count"] || 0) +
          (summary["send_event_count"] || 0) +
          (summary["receive_event_count"] || 0)

      assert total_sidecar_events > 0,
             "fixture #{fixture.name} produced an empty sidecar (recorder traced nothing)"

      fixture.oracle.(summary)
    end
  end

  defp run_fixture!(name, eval) do
    out_dir = tmp_dir!("m17-#{name}-out")
    build_root = tmp_dir!("m17-#{name}-build")
    fixture_dir = Path.join(@fixtures_root, name)

    compile!(fixture_dir, build_root)

    {output, status} =
      System.cmd(
        recorder_binary!(),
        [
          "record",
          "--out-dir",
          out_dir,
          "--",
          "mix",
          "run",
          "--no-compile",
          "-e",
          eval
        ],
        cd: fixture_dir,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0,
           """
           recorder failed for fixture #{name} with status #{status}

           #{output}
           """

    read_bundle_summary!(out_dir)
  end

  defp compile!(fixture_dir, build_root) do
    {output, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: fixture_dir,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", build_root}],
        stderr_to_stdout: true
      )

    assert status == 0,
           "mix compile for fixture #{Path.basename(fixture_dir)} failed: #{output}"
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
        flunk("codetracer-beam-recorder binary not built; run `cargo build --locked` first")
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

    path =
      Path.join(System.tmp_dir!(), "codetracer-beam-recorder-#{label}-#{pid}-#{nonce}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
