ExUnit.start()

defmodule CodetracerBeamRecorder.NativeTracerParityTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M16 verification: drives the canonical Elixir and Erlang fixtures under
  *both* the reference `process` tracer backend and the new `native`
  backend, then opens both bundles through the same `NimTraceReaderHandle`
  reader (via `read-bundle-summary`) and asserts the two recordings
  expose the same event classes, the same module/function metadata, and
  matching shutdown semantics.

  The two bundles are not byte-identical — the native path stamps every
  event with a sequence number and writes a `"backend":"native"` marker
  on every line — but the *set* of trace events surfaced through the
  reader must agree.
  """

  @repo_root Path.expand("../..", __DIR__)
  @elixir_fixture Path.join(@repo_root, "test-programs/elixir/canonical_flow")
  @erlang_fixture Path.join(@repo_root, "test-programs/erlang/canonical_flow")

  test "e2e_native_tracer_event_parity" do
    # ----- Erlang canonical fixture -----
    process_erl = run_erlang_fixture!("erl-process", "process")
    native_erl = run_erlang_fixture!("erl-native", "native")

    assert process_erl["runtime_session_delivered"] == true
    assert native_erl["runtime_session_delivered"] == true
    assert process_erl["sidecar_trace_delivered"] == true
    assert native_erl["sidecar_trace_delivered"] == true

    # Reader-visible thread lifecycle equivalence: both must record at
    # least one root thread_start and one root thread_exit.
    assert process_erl["thread_start_count_root"] == 1
    assert native_erl["thread_start_count_root"] == 1
    assert process_erl["thread_exit_count_root"] == 1
    assert native_erl["thread_exit_count_root"] == 1

    # The native sidecar must include the M16 backend marker on every
    # event line.
    assert backend_marker_present?(out_dir_for("erl-native")),
           "native bundle's runtime_session.jsonl must include \"backend\":\"native\" markers"

    # The native bundle must include the `trace_delivered` summary line
    # carrying the per-session event_count and overflow status, written
    # by codetracer_native_tracer:stop/2 (M16 shutdown barrier).
    assert native_trace_delivered_summary?(out_dir_for("erl-native")),
           "native bundle must finalize through trace_delivered with event_count + overflow status"

    # ----- Elixir canonical fixture -----
    process_ex = run_elixir_fixture!("ex-process", "process")
    native_ex = run_elixir_fixture!("ex-native", "native")

    assert process_ex["runtime_session_delivered"] == true
    assert native_ex["runtime_session_delivered"] == true
    assert process_ex["sidecar_trace_delivered"] == true
    assert native_ex["sidecar_trace_delivered"] == true

    # The Elixir canonical fixture exercises trace_pattern-driven calls,
    # so both backends must report a non-zero sidecar_call_count.
    assert process_ex["sidecar_call_count"] >= 1
    assert native_ex["sidecar_call_count"] >= 1

    # Equivalent call/return counts: returns must equal calls in both
    # backends (no exception unwinds in the canonical fixture).
    assert process_ex["sidecar_call_count"] == process_ex["sidecar_return_count"]
    assert native_ex["sidecar_call_count"] == native_ex["sidecar_return_count"]

    # Identical *set* of recorded modules across both backends.
    process_modules = call_modules_for(out_dir_for("ex-process"))
    native_modules = call_modules_for(out_dir_for("ex-native"))

    assert process_modules == native_modules,
           """
           native and process backends must surface the same set of module
           names through their recorded `call` events. process=#{inspect(process_modules)}
           native=#{inspect(native_modules)}
           """

    # Identical set of recorded MFAs.
    process_mfas = call_mfas_for(out_dir_for("ex-process"))
    native_mfas = call_mfas_for(out_dir_for("ex-native"))

    assert process_mfas == native_mfas,
           """
           native and process backends must record the same set of {module, function, arity}
           triples for trace-pattern-driven calls.
           process=#{inspect(process_mfas)}
           native=#{inspect(native_mfas)}
           """
  end

  defp run_erlang_fixture!(label, backend) do
    out_dir = ensure_out_dir!(label)
    ebin_dir = tmp_dir!("native-tracer-erl-ebin-#{label}")
    compile_erlang_fixture!(ebin_dir)

    {output, status} =
      System.cmd(
        recorder_binary!(),
        [
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
          "canonical_flow",
          "main",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_fixture,
        stderr_to_stdout: true
      )

    assert status == 0, """
    erlang #{backend} record failed with status #{status}

    #{output}
    """

    read_bundle_summary!(out_dir)
  end

  defp run_elixir_fixture!(label, backend) do
    out_dir = ensure_out_dir!(label)
    mix_build_root = tmp_dir!("native-tracer-ex-build-#{label}")
    compile_elixir_fixture!(mix_build_root)

    {output, status} =
      System.cmd(
        recorder_binary!(),
        [
          "record",
          "--out-dir",
          out_dir,
          "--tracer-backend",
          backend,
          "--",
          "mix",
          "run",
          "--no-compile",
          "-e",
          "CanonicalFlow.main()"
        ],
        cd: @elixir_fixture,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", mix_build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, """
    elixir #{backend} record failed with status #{status}

    #{output}
    """

    read_bundle_summary!(out_dir)
  end

  defp ensure_out_dir!(label) do
    case Process.get({:out_dir, label}) do
      nil ->
        path = tmp_dir!("native-tracer-parity-#{label}")
        Process.put({:out_dir, label}, path)
        path

      path ->
        path
    end
  end

  defp out_dir_for(label) do
    Process.get({:out_dir, label}) ||
      flunk("out dir for label #{label} was not initialized")
  end

  defp backend_marker_present?(out_dir) do
    out_dir
    |> Path.join("runtime_session.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line -> String.contains?(line, "\"backend\":\"native\"") end)
  end

  defp native_trace_delivered_summary?(out_dir) do
    out_dir
    |> Path.join("runtime_session.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line ->
      String.contains?(line, "\"event\":\"trace_delivered\"") and
        String.contains?(line, "\"event_count\":") and
        String.contains?(line, "\"overflow_policy\":")
    end)
  end

  defp call_modules_for(out_dir) do
    out_dir
    |> Path.join("runtime_session.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      cond do
        not String.contains?(line, "\"event\":\"call\"") -> []
        true -> Regex.run(~r/"module":"([^"]+)"/, line, capture: :all_but_first) || []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp call_mfas_for(out_dir) do
    out_dir
    |> Path.join("runtime_session.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      cond do
        not String.contains?(line, "\"event\":\"call\"") ->
          []

        true ->
          with [module] <- Regex.run(~r/"module":"([^"]+)"/, line, capture: :all_but_first),
               [function] <- Regex.run(~r/"function":"([^"]+)"/, line, capture: :all_but_first),
               [arity] <- Regex.run(~r/"arity":(\d+)/, line, capture: :all_but_first) do
            [{module, function, String.to_integer(arity)}]
          else
            _ -> []
          end
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
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

  # Minimal recursive-descent JSON decoder, sufficient for the
  # deterministic one-line output that read-bundle-summary emits.
  defp decode_json!(input), do: parse_value(skip_ws(input))

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
      Path.join(
        System.tmp_dir!(),
        "codetracer-beam-recorder-m16-#{label}-#{pid}-#{nonce}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp compile_elixir_fixture!(mix_build_root) do
    {clean_output, clean_status} =
      System.cmd("mix", ["clean"],
        cd: @elixir_fixture,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", mix_build_root}],
        stderr_to_stdout: true
      )

    assert clean_status == 0, "mix clean failed: #{clean_output}"

    {compile_output, compile_status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: @elixir_fixture,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", mix_build_root}],
        stderr_to_stdout: true
      )

    assert compile_status == 0, "mix compile failed: #{compile_output}"
  end

  defp compile_erlang_fixture!(ebin_dir) do
    File.mkdir_p!(ebin_dir)

    for source <- [
          Path.join(@erlang_fixture, "src/canonical_flow.erl"),
          Path.join(@erlang_fixture, "test/canonical_flow_tests.erl")
        ] do
      {output, status} =
        System.cmd("erlc", ["+debug_info", "-o", ebin_dir, source], stderr_to_stdout: true)

      assert status == 0, "erlc #{source} failed: #{output}"
    end
  end
end
