ExUnit.start()

defmodule CodetracerBeamRecorder.PlugSmokeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M17 verification: records the request-oriented Elixir fixture
  `test-programs/elixir/plug_smoke` serving a single HTTP/1.1 GET
  request through `:gen_tcp`, then asserts the recorded bundle
  contains the request handler call sequence
  (`PlugSmoke.Router.route/1` -> `dispatch/2` -> `render/2`).

  The fixture intentionally does NOT pull in the `:plug` Hex package
  because the recorder dev shell is offline. The router is shaped
  like `Plug.Router` so a future swap to real Plug + Cowboy is
  mechanical. The recorder contract under test — `record` exits 0,
  the bundle is reader-loadable, the request handler call sequence
  is present — is the same contract a Phoenix `--no-html --no-ecto`
  app would exercise.
  """

  @repo_root Path.expand("../..", __DIR__)
  @fixture_dir Path.join(@repo_root, "test-programs/elixir/plug_smoke")

  test "e2e_phoenix_or_plug_smoke_real_trace" do
    out_dir = tmp_dir!("m17-plug-smoke")
    build_root = tmp_dir!("m17-plug-smoke-build")
    compile!(build_root)

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
          "PlugSmoke.main()"
        ],
        cd: @fixture_dir,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", build_root}],
        stderr_to_stdout: true
      )

    assert status == 0,
           """
           plug-smoke recorder run failed with status #{status}

           #{output}
           """

    assert String.contains?(output, "plug-smoke-ok"),
           "fixture must report plug-smoke-ok on stdout, got: #{output}"

    summary = read_bundle_summary!(out_dir)

    assert summary["status"] == "ok"
    assert summary["language"] == "elixir"
    assert summary["runtime_session_delivered"] == true
    assert summary["sidecar_trace_delivered"] == true,
           "request fixture must finalize through trace_delivered"

    # The request fixture spawns a server process and exchanges
    # request/response messages over :gen_tcp. The recorder must see
    # at least one process spawn and message traffic for the
    # client/server hand-off.
    assert summary["process_spawn_count"] >= 1,
           "expected the server process spawn to be recorded"

    assert summary["send_event_count"] >= 1,
           "expected request/response message traffic on the wire"

    assert summary["receive_event_count"] >= 1

    # Verify the request handler call sequence
    # PlugSmoke.Router.route/1 -> dispatch/2 -> render/2 — landed in
    # the runtime session sidecar. We grep the sidecar JSONL directly
    # because the read-bundle-summary projection does not surface
    # per-MFA call counts, only aggregates.
    sidecar = Path.join(out_dir, "runtime_session.jsonl")

    text =
      sidecar
      |> File.read!()
      |> String.split("\n", trim: true)

    handler_calls =
      for line <- text,
          String.contains?(line, "\"event\":\"call\""),
          String.contains?(line, "\"module\":\"Elixir.PlugSmoke.Router\"") do
        cond do
          String.contains?(line, "\"function\":\"route\"") -> :route
          String.contains?(line, "\"function\":\"dispatch\"") -> :dispatch
          String.contains?(line, "\"function\":\"render\"") -> :render
          true -> :other
        end
      end

    assert :route in handler_calls,
           """
           expected PlugSmoke.Router.route/1 to be recorded as a call event.
           Recorded handler calls: #{inspect(handler_calls)}.
           sidecar=#{sidecar}
           """

    assert :dispatch in handler_calls,
           "expected PlugSmoke.Router.dispatch/2 to be recorded; got #{inspect(handler_calls)}"

    assert :render in handler_calls,
           "expected PlugSmoke.Router.render/2 to be recorded; got #{inspect(handler_calls)}"
  end

  defp compile!(build_root) do
    {output, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: @fixture_dir,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_ROOT", build_root}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix compile failed for plug_smoke fixture: #{output}"
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
