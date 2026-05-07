ExUnit.start()

defmodule CodetracerBeamRecorder.RuntimeSessionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M4 sub-phase 3 verification: drives the real Elixir and Erlang canonical
  fixtures under the codetracer-beam-recorder runtime session, then opens the
  produced CTFS bundle through the same `NimTraceReaderHandle` reader bridge
  used by `ctfs_writer_bridge_test.exs` (via the recorder binary's
  `read-bundle-summary` subcommand). The tests assert the M4 lifecycle
  contract — exactly one root ThreadStart, at least one root ThreadSwitch,
  exactly one root ThreadExit, copied source files, and CTFS-only output with
  language metadata identifying the BEAM source language.
  """

  @repo_root Path.expand("../..", __DIR__)
  @elixir_fixture Path.join(@repo_root, "test-programs/elixir/canonical_flow")
  @erlang_fixture Path.join(@repo_root, "test-programs/erlang/canonical_flow")

  test "e2e_runtime_session_records_real_elixir_process" do
    out_dir = tmp_dir!("runtime-elixir")
    mix_build_root = tmp_dir!("runtime-elixir-build")
    compile_elixir_fixture!(mix_build_root)

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
        cd: @elixir_fixture,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", mix_build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, """
    elixir runtime session record failed with status #{status}

    #{output}
    """

    summary = read_bundle_summary!(out_dir)

    assert summary["status"] == "ok"
    assert summary["format"] == "ctfs"
    assert summary["reader"] == "codetracer_trace_writer_nim::NimTraceReaderHandle"
    assert summary["language"] == "elixir",
           "trace_meta.json language must identify Elixir trace, got: #{inspect(summary["language"])}"
    assert summary["trace_meta_format"] == "ctfs"
    assert summary["runtime_session_mode"] == "beam"
    assert summary["runtime_session_delivered"] == true
    assert summary["runtime_session_root_thread_id"] == 1
    assert is_binary(summary["runtime_session_root_pid"]),
           "trace_meta.json must record the root BEAM pid"

    assert summary["thread_start_count_root"] == 1,
           "expected exactly one root ThreadStart, got #{summary["thread_start_count_root"]}"
    assert summary["thread_switch_count_root"] >= 1,
           "expected at least one root ThreadSwitch, got #{summary["thread_switch_count_root"]}"
    assert summary["thread_exit_count_root"] == 1,
           "expected exactly one root ThreadExit, got #{summary["thread_exit_count_root"]}"

    assert summary["sidecar_trace_delivered"] == true,
           "session must finalize through erlang:trace_delivered(all) before flushing the writer"

    sources = summary["sources"]
    assert is_list(sources)
    assert Enum.any?(sources, fn path -> String.ends_with?(path, "lib/canonical_flow.ex") end),
           "expected canonical Elixir source to be copied into the trace bundle: #{inspect(sources)}"

    bundle_source =
      Path.join([out_dir, "source_map", "lib", "canonical_flow.ex"])

    assert File.exists?(bundle_source),
           "expected canonical Elixir source copied into bundle at #{bundle_source}"
  end

  test "e2e_runtime_session_records_real_erlang_process" do
    out_dir = tmp_dir!("runtime-erlang")
    ebin_dir = tmp_dir!("runtime-erlang-ebin")
    compile_erlang_fixture!(ebin_dir)

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
        cd: @erlang_fixture,
        stderr_to_stdout: true
      )

    assert status == 0, """
    erlang runtime session record failed with status #{status}

    #{output}
    """

    summary = read_bundle_summary!(out_dir)

    assert summary["status"] == "ok"
    assert summary["format"] == "ctfs"
    assert summary["reader"] == "codetracer_trace_writer_nim::NimTraceReaderHandle"
    assert summary["language"] == "erlang",
           "trace_meta.json language must identify Erlang trace, got: #{inspect(summary["language"])}"
    assert summary["trace_meta_format"] == "ctfs"
    assert summary["runtime_session_mode"] == "beam"
    assert summary["runtime_session_delivered"] == true
    assert summary["runtime_session_root_thread_id"] == 1
    assert is_binary(summary["runtime_session_root_pid"]),
           "trace_meta.json must record the root BEAM pid"

    assert summary["thread_start_count_root"] == 1,
           "expected exactly one root ThreadStart, got #{summary["thread_start_count_root"]}"
    assert summary["thread_switch_count_root"] >= 1,
           "expected at least one root ThreadSwitch, got #{summary["thread_switch_count_root"]}"
    assert summary["thread_exit_count_root"] == 1,
           "expected exactly one root ThreadExit, got #{summary["thread_exit_count_root"]}"

    assert summary["sidecar_trace_delivered"] == true,
           "session must finalize through erlang:trace_delivered(all) before flushing the writer"

    sources = summary["sources"]
    assert is_list(sources)
    assert Enum.any?(sources, fn path -> String.ends_with?(path, "src/canonical_flow.erl") end),
           "expected canonical Erlang source to be copied into the trace bundle: #{inspect(sources)}"

    bundle_source =
      Path.join([out_dir, "source_map", "src", "canonical_flow.erl"])

    assert File.exists?(bundle_source),
           "expected canonical Erlang source copied into bundle at #{bundle_source}"
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

  # Minimal recursive-descent JSON decoder, sufficient for the deterministic
  # one-line output that read-bundle-summary emits. This keeps the integration
  # test free of external Elixir dependencies.
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
        "codetracer-beam-recorder-m4-#{label}-#{pid}-#{nonce}"
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
