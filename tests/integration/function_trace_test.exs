ExUnit.start()

defmodule CodetracerBeamRecorder.FunctionTraceTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M5 verification: drives the real Elixir and Erlang canonical fixtures plus
  the `exception_flow` crash fixture under codetracer-beam-recorder, then
  reads the produced CTFS bundle through the recorder binary's
  `read-bundle-summary` subcommand (which wraps the same
  `NimTraceReaderHandle` reader that downstream tooling will use).

  The asserted contract for M5 follows the canonical_flow first-principles
  golden under `tests/goldens/canonical_flow/first-principles.org`:

    - `main/0` and `compute/0` are interned through recorder-owned function
      interning and queryable through the trace reader's function table.
    - `register_call` and `register_return` produce two paired call records
      mirroring the source-order Call(main) -> Call(compute) -> Return(94)
      -> Return(94) sequence.
    - When the recorded program raises an uncaught exception, the CTFS
      bundle contains an `exception_from` special event for every traced
      MFA the exception unwinds through, the recorder preserves the
      target's non-zero exit code, and the runtime sidecar records the
      same event count.

  These tests intentionally use the real recorder binary, the real BEAM
  toolchain, and the real CTFS reader — there are no mocks, fakes, or
  stubs. The accompanying `verify-function-trace-test-no-silent-skip.sh`
  guard fails the build if any of those guarantees regress.
  """

  @repo_root Path.expand("../..", __DIR__)
  @elixir_canonical Path.join(@repo_root, "test-programs/elixir/canonical_flow")
  @erlang_canonical Path.join(@repo_root, "test-programs/erlang/canonical_flow")
  @elixir_exception Path.join(@repo_root, "test-programs/elixir/exception_flow")

  test "e2e_runtime_records_canonical_call_return_sequence" do
    out_dir = tmp_dir!("m5-elixir-call-return")
    mix_build_root = tmp_dir!("m5-elixir-call-return-build")
    compile_elixir_fixture!(@elixir_canonical, mix_build_root)

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
          "CanonicalFlow.main()"
        ],
        cd: @elixir_canonical,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", mix_build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, """
    canonical Elixir call/return record failed with status #{status}

    #{output}
    """

    summary = read_bundle_summary!(out_dir)

    assert summary["language"] == "elixir"
    assert summary["runtime_session_delivered"] == true
    assert summary["target_exit_code"] == 0,
           "canonical Elixir fixture must exit 0; trace_meta target.exit_code was #{summary["target_exit_code"]}"

    # First-principles golden: Call(main) -> Call(compute) -> Return(94) ->
    # Return(94). The recorder's function interner must hand out exactly two
    # FunctionRecords keyed by {module,name,arity,kind,defining_loc}.
    assert summary["function_count"] == 2,
           "expected exactly 2 interned functions for canonical_flow, got #{summary["function_count"]}: #{inspect(summary["function_names"])}"

    assert "CanonicalFlow.main/0" in summary["function_names"],
           "function table must contain CanonicalFlow.main/0; got #{inspect(summary["function_names"])}"

    assert "CanonicalFlow.compute/0" in summary["function_names"],
           "function table must contain CanonicalFlow.compute/0; got #{inspect(summary["function_names"])}"

    main_id = Enum.find_index(summary["function_names"], &(&1 == "CanonicalFlow.main/0"))
    compute_id = Enum.find_index(summary["function_names"], &(&1 == "CanonicalFlow.compute/0"))

    # The runtime sidecar must record both call entries and both return
    # entries before the writer ever sees them — this proves erlang:trace/3
    # 'call' tracing is on for the user module and trace_pattern installed
    # `return` tracing for both selected MFAs.
    assert summary["sidecar_call_count"] == 2,
           "runtime session sidecar must contain 2 call lines; got #{summary["sidecar_call_count"]}"

    assert summary["sidecar_return_count"] == 2,
           "runtime session sidecar must contain 2 return_from lines; got #{summary["sidecar_return_count"]}"

    assert summary["sidecar_exception_from_count"] == 0,
           "canonical_flow must not emit exception_from; got #{summary["sidecar_exception_from_count"]}"

    # The CTFS reader must surface both calls with the same function_ids the
    # interner handed out. Order in `call_function_ids` is completion order:
    # compute completes before main returns, so compute's record comes first.
    assert summary["call_count"] == 2,
           "expected exactly 2 paired call records in the CTFS bundle; got #{summary["call_count"]}"

    assert summary["call_function_ids"] == [compute_id, main_id],
           "expected call records [compute, main] (completion order); got #{inspect(summary["call_function_ids"])} with names #{inspect(summary["function_names"])}"
  end

  test "e2e_runtime_records_real_exception_fixture" do
    out_dir = tmp_dir!("m5-elixir-crash")
    mix_build_root = tmp_dir!("m5-elixir-crash-build")
    compile_elixir_fixture!(@elixir_exception, mix_build_root)

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
          "ExceptionFlow.crash()"
        ],
        cd: @elixir_exception,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", mix_build_root}
        ],
        stderr_to_stdout: true
      )

    # The crash fixture deterministically raises an uncaught ArgumentError;
    # the BEAM process must exit non-zero and the recorder must propagate
    # that exit code.
    refute status == 0,
           "ExceptionFlow.crash must exit non-zero; got status=0\n\n#{output}"

    summary = read_bundle_summary!(out_dir)

    assert summary["language"] == "elixir"
    assert summary["runtime_session_delivered"] == true
    assert summary["target_exit_code"] == status,
           "trace_meta.json target.exit_code (#{summary["target_exit_code"]}) must match the recorder's exit (#{status})"

    refute summary["target_exit_code"] == 0,
           "M5 contract: recorder must preserve non-zero exit on uncaught exceptions; got 0"

    assert summary["function_count"] >= 2,
           "function table must contain crash and crash_inner; got #{summary["function_count"]}: #{inspect(summary["function_names"])}"

    assert "ExceptionFlow.crash/0" in summary["function_names"]
    assert "ExceptionFlow.crash_inner/0" in summary["function_names"]

    # The runtime sidecar records exactly two exception_from lines (one for
    # each unwound MFA) and zero return_from lines (every traced call
    # exited via exception, not return).
    assert summary["sidecar_call_count"] == 2,
           "expected 2 sidecar call lines for crash/crash_inner; got #{summary["sidecar_call_count"]}"

    assert summary["sidecar_return_count"] == 0,
           "expected 0 sidecar return_from lines on uncaught crash; got #{summary["sidecar_return_count"]}"

    assert summary["sidecar_exception_from_count"] == 2,
           "expected 2 sidecar exception_from lines on the unwound stack; got #{summary["sidecar_exception_from_count"]}"

    # Through the real CTFS reader: every exception_from special event must
    # carry the BEAM exception schema with MFA + class metadata so the
    # downstream debugger can reconstruct the failure.
    assert summary["exception_from_count"] >= 2,
           "CTFS bundle must contain >=2 exception_from special events; got #{summary["exception_from_count"]}"

    crash_inner =
      Enum.find(summary["exception_from_records"], fn record ->
        record["module"] == "Elixir.ExceptionFlow" and record["function"] == "crash_inner"
      end)

    assert crash_inner != nil,
           "expected exception_from record for ExceptionFlow.crash_inner/0; got #{inspect(summary["exception_from_records"])}"

    assert crash_inner["arity"] == 0
    assert crash_inner["class"] == "error",
           "ArgumentError must be classified as :error; got #{crash_inner["class"]}"

    assert String.contains?(crash_inner["schema"], "exception_from"),
           "exception payload schema must include 'exception_from'; got #{crash_inner["schema"]}"

    crash_outer =
      Enum.find(summary["exception_from_records"], fn record ->
        record["module"] == "Elixir.ExceptionFlow" and record["function"] == "crash"
      end)

    assert crash_outer != nil,
           "expected exception_from record for outer ExceptionFlow.crash/0 frame; got #{inspect(summary["exception_from_records"])}"
  end

  test "e2e_runtime_call_trace_reader_roundtrip" do
    # Reuses the canonical Erlang fixture for a second language coverage of
    # the reader roundtrip. Erlang's `canonical_flow:main/0` and `compute/0`
    # exercise the same first-principles golden against a different BEAM
    # frontend.
    out_dir = tmp_dir!("m5-erlang-roundtrip")
    ebin_dir = tmp_dir!("m5-erlang-roundtrip-ebin")
    compile_erlang_fixture!(@erlang_canonical, ebin_dir)

    {output, status} =
      System.cmd(
        recorder_binary!(),
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
          "canonical_flow",
          "main",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_canonical,
        stderr_to_stdout: true
      )

    assert status == 0, """
    canonical Erlang reader-roundtrip record failed with status #{status}

    #{output}
    """

    summary = read_bundle_summary!(out_dir)

    assert summary["language"] == "erlang"
    assert summary["target_exit_code"] == 0
    assert summary["runtime_session_delivered"] == true

    # Real reader: function records, call records, and event records must
    # all be queryable through the same NimTraceReaderHandle that
    # ctfs_writer_bridge_test.exs uses.
    assert summary["function_count"] == 2,
           "expected 2 interned functions; got #{summary["function_count"]}: #{inspect(summary["function_names"])}"

    assert "canonical_flow:main/0" in summary["function_names"]
    assert "canonical_flow:compute/0" in summary["function_names"]

    assert summary["call_count"] == 2,
           "expected 2 paired call records via NimTraceReaderHandle::call_count; got #{summary["call_count"]}"

    main_id =
      Enum.find_index(summary["function_names"], &(&1 == "canonical_flow:main/0"))

    compute_id =
      Enum.find_index(summary["function_names"], &(&1 == "canonical_flow:compute/0"))

    assert summary["call_function_ids"] == [compute_id, main_id],
           "expected call records [compute, main]; got #{inspect(summary["call_function_ids"])}"

    # `call_json` is the raw output of `NimTraceReaderHandle::call_json` — it
    # must round-trip through serde and contain the parent/child structure.
    assert length(summary["call_json"]) == 2

    [compute_call_json, main_call_json] = summary["call_json"]

    assert String.contains?(compute_call_json, "\"function_id\":#{compute_id}"),
           "first call_json must reference compute's function_id; got #{compute_call_json}"

    assert String.contains?(main_call_json, "\"function_id\":#{main_id}"),
           "second call_json must reference main's function_id; got #{main_call_json}"

    assert String.contains?(main_call_json, "\"children\":[0]"),
           "main's call record must list compute as a child call key; got #{main_call_json}"

    # event_count and step_count are non-zero — meaning the reader is
    # actually decoding the bundle, not silently returning empties.
    assert summary["event_count"] > 0
    assert summary["step_count"] > 0
    assert summary["path_count"] > 0
  end

  defp recorder_binary! do
    case System.get_env("CODETRACER_BEAM_RECORDER_BIN") do
      nil ->
        debug = Path.join([@repo_root, "target", "debug", "codetracer-beam-recorder"])
        release = Path.join([@repo_root, "target", "release", "codetracer-beam-recorder"])

        cond do
          File.exists?(debug) ->
            debug

          File.exists?(release) ->
            release

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

  defp read_bundle_summary!(out_dir) do
    {output, status} =
      System.cmd(
        recorder_binary!(),
        ["read-bundle-summary", "--bundle", out_dir],
        stderr_to_stdout: true
      )

    assert status == 0, """
    read-bundle-summary failed with status #{status}

    #{output}
    """

    last_line =
      output
      |> String.split("\n", trim: true)
      |> List.last()

    {decoded, _rest} = decode_json!(last_line)
    decoded
  end

  # Minimal recursive-descent JSON decoder, sufficient for the deterministic
  # one-line output that read-bundle-summary emits. Mirrors the decoder in
  # runtime_session_test.exs so the M5 tests stay free of external Elixir
  # dependencies.
  defp decode_json!(input) do
    parse_value(skip_ws(input))
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

  defp parse_string_chars(<<?\\, ?", rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> "\"")

  defp parse_string_chars(<<?\\, ?\\, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> "\\")

  defp parse_string_chars(<<?\\, ?n, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> "\n")

  defp parse_string_chars(<<?\\, ?t, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> "\t")

  defp parse_string_chars(<<?\\, ?r, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> "\r")

  defp parse_string_chars(<<?\\, ?/, rest::binary>>, acc),
    do: parse_string_chars(rest, acc <> "/")

  defp parse_string_chars(<<char::utf8, rest::binary>>, acc) do
    parse_string_chars(rest, acc <> <<char::utf8>>)
  end

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
      Path.join(
        System.tmp_dir!(),
        "codetracer-beam-recorder-m5-#{label}-#{pid}-#{nonce}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp compile_elixir_fixture!(fixture_dir, mix_build_root) do
    {clean_output, clean_status} =
      System.cmd("mix", ["clean"],
        cd: fixture_dir,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", mix_build_root}],
        stderr_to_stdout: true
      )

    assert clean_status == 0, "mix clean failed for #{fixture_dir}: #{clean_output}"

    {compile_output, compile_status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: fixture_dir,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", mix_build_root}],
        stderr_to_stdout: true
      )

    assert compile_status == 0, "mix compile failed for #{fixture_dir}: #{compile_output}"
  end

  defp compile_erlang_fixture!(fixture_dir, ebin_dir) do
    File.mkdir_p!(ebin_dir)

    src = Path.join(fixture_dir, "src/canonical_flow.erl")

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, src], stderr_to_stdout: true)

    assert status == 0, "erlc #{src} failed: #{output}"
  end
end
