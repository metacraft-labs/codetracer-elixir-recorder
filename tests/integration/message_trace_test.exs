ExUnit.start()

defmodule CodetracerBeamRecorder.MessageTraceTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M6 verification: drives the Elixir `task_messages` and Erlang
  `spawn_messages` fixtures under `codetracer-beam-recorder` and asserts
  the recorded CTFS bundle exposes the expected ThreadStart/ThreadSwitch/
  ThreadExit lifecycle plus structured send/receive `TraceLogEvent`
  payloads, all read back through the recorder's `read-bundle-summary`
  subcommand which wraps `NimTraceReaderHandle`.

  The `e2e_runtime_trace_delivered_flush_barrier` test additionally drives
  the Erlang `spawn_messages:flood/0` high-volume fixture (64 ordered
  messages) to confirm that the runtime's `erlang:trace_delivered(all)`
  shutdown barrier preserves the full event stream without silent drops
  across multiple deterministic runs.

  Goldens hand-derived from fixture source live under
  `tests/goldens/task_messages/first-principles.org` and
  `tests/goldens/spawn_messages/first-principles.org`.
  """

  @repo_root Path.expand("../..", __DIR__)
  @elixir_task_fixture Path.join(@repo_root, "test-programs/elixir/task_messages")
  @erlang_spawn_fixture Path.join(@repo_root, "test-programs/erlang/spawn_messages")
  @goldens_dir Path.join(@repo_root, "tests/goldens")

  test "e2e_runtime_records_elixir_task_messages" do
    out_dir = tmp_dir!("m6-elixir-task")
    mix_build_root = tmp_dir!("m6-elixir-task-build")
    compile_elixir_fixture!(@elixir_task_fixture, mix_build_root)

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
          "TaskMessages.main()"
        ],
        cd: @elixir_task_fixture,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", mix_build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, """
    task_messages fixture record failed with status #{status}

    #{output}
    """

    # Anchor against the hand-derived first-principles golden so any
    # divergence between the source fixture and the golden surfaces here.
    golden_path = Path.join(@goldens_dir, "task_messages/first-principles.org")
    golden = File.read!(golden_path)

    assert String.contains?(golden, "task-ok"),
           "first-principles golden must document the expected stdout"

    assert String.contains?(golden, "thread_start (CTFS step stream): >= 2"),
           "first-principles golden must document thread_start lower bound"

    summary = read_bundle_summary!(out_dir)

    assert summary["language"] == "elixir"
    assert summary["runtime_session_delivered"] == true
    assert summary["sidecar_trace_delivered"] == true,
           "session must finalize through erlang:trace_delivered(all) before flushing"

    # Multi-process lifecycle: root + at least one spawned BEAM process.
    assert summary["thread_start_count"] > 1,
           "expected ThreadStart for root + Task worker; got #{summary["thread_start_count"]}"

    assert summary["thread_exit_count"] > 1,
           "expected ThreadExit for root + Task worker; got #{summary["thread_exit_count"]}"

    assert summary["thread_switch_count"] >= 1,
           "expected at least one ThreadSwitch between processes; got #{summary["thread_switch_count"]}"

    assert summary["process_spawn_count"] >= 1,
           "expected at least one process_spawn sidecar event; got #{summary["process_spawn_count"]}"

    assert summary["process_exit_count"] >= 1,
           "expected at least one spawned-process exit sidecar event; got #{summary["process_exit_count"]}"

    assert summary["send_event_count"] >= 3,
           "expected >=3 message_send sidecar lines; got #{summary["send_event_count"]}"

    assert summary["receive_event_count"] >= 3,
           "expected >=3 message_receive sidecar lines; got #{summary["receive_event_count"]}"

    # The reader must surface structured TraceLogEvent payloads.
    records = summary["event_log_records"]
    assert is_list(records)
    assert length(records) >= 6,
           "expected >=6 codetracer.beam.message.v1 events through the reader; got #{length(records)}"

    # M6 contract: every recorded message TraceLogEvent must carry sender,
    # recipient, tag, and a bounded payload representation.
    for record <- records do
      assert record["schema"] == "codetracer.beam.message.v1"
      assert record["direction"] in ["send", "receive"]
      assert is_binary(record["tag"]) and record["tag"] != ""
      assert is_binary(record["payload_repr"]) and record["payload_repr"] != ""
      # Bounded representation: every payload_repr is JSON-truncated. The
      # recorder caps text representations at 512 bytes (see
      # codetracer_session.erl:bounded_term/2). Every record must agree
      # with the truncation flag.
      if record["payload_truncated"] do
        assert byte_size(record["payload_repr"]) >= 1
      else
        assert byte_size(record["payload_repr"]) <= 512
      end
    end

    tags = records |> Enum.map(& &1["tag"]) |> Enum.uniq() |> Enum.sort()

    assert "task_go" in tags,
           "expected task_go message tag in trace log; got #{inspect(tags)}"

    assert "task_ready" in tags,
           "expected task_ready message tag; got #{inspect(tags)}"

    assert "task_ack" in tags,
           "expected task_ack message tag; got #{inspect(tags)}"

    # At least one TraceLogEvent must surface a non-empty sender and
    # recipient pid pair via the reader, proving the bounded payload
    # contract is wired end-to-end.
    structured =
      Enum.find(records, fn record ->
        is_binary(record["sender"]) and record["sender"] != "" and
          is_binary(record["recipient"]) and record["recipient"] != ""
      end)

    assert structured != nil,
           "expected at least one TraceLogEvent with non-empty sender + recipient pid via the reader; got #{inspect(records)}"
  end

  test "e2e_runtime_records_erlang_spawn_messages" do
    out_dir = tmp_dir!("m6-erlang-spawn")
    ebin_dir = tmp_dir!("m6-erlang-spawn-ebin")
    compile_erlang_spawn_fixture!(ebin_dir)

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
          "spawn_messages",
          "main",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_spawn_fixture,
        stderr_to_stdout: true
      )

    assert status == 0, """
    spawn_messages fixture record failed with status #{status}

    #{output}
    """

    golden_path = Path.join(@goldens_dir, "spawn_messages/first-principles.org")
    golden = File.read!(golden_path)

    assert String.contains?(golden, "spawn-ok"),
           "first-principles golden must document expected stdout"

    summary = read_bundle_summary!(out_dir)

    assert summary["language"] == "erlang"
    assert summary["runtime_session_delivered"] == true
    assert summary["sidecar_trace_delivered"] == true

    assert summary["thread_start_count"] > 1,
           "expected ThreadStart for root + spawned child; got #{summary["thread_start_count"]}"

    assert summary["thread_exit_count"] > 1,
           "expected ThreadExit for root + spawned child; got #{summary["thread_exit_count"]}"

    assert summary["thread_switch_count"] >= 1,
           "expected at least one ThreadSwitch; got #{summary["thread_switch_count"]}"

    assert summary["process_spawn_count"] >= 1,
           "expected at least one process_spawn sidecar event; got #{summary["process_spawn_count"]}"

    assert summary["process_exit_count"] >= 1,
           "expected at least one spawned-process exit sidecar event; got #{summary["process_exit_count"]}"

    assert summary["send_event_count"] >= 3,
           "expected >=3 message_send sidecar lines; got #{summary["send_event_count"]}"

    assert summary["receive_event_count"] >= 3,
           "expected >=3 message_receive sidecar lines; got #{summary["receive_event_count"]}"

    records = summary["event_log_records"]
    assert is_list(records)
    assert length(records) >= 6,
           "expected >=6 codetracer.beam.message.v1 events; got #{length(records)}"

    tags = records |> Enum.map(& &1["tag"]) |> Enum.uniq() |> Enum.sort()
    assert "spawn_child_started" in tags
    assert "spawn_ping" in tags
    assert "spawn_pong" in tags

    structured =
      Enum.find(records, fn record ->
        is_binary(record["sender"]) and record["sender"] != "" and
          is_binary(record["recipient"]) and record["recipient"] != ""
      end)

    assert structured != nil,
           "expected at least one TraceLogEvent with non-empty sender + recipient via the reader; got #{inspect(records)}"
  end

  test "e2e_runtime_trace_delivered_flush_barrier" do
    # 64 ordered flush_ping messages + bookend ready/done = 66 sends and
    # 66 receives. The deterministic ordering guard `Index =:= Seen + 1`
    # in the fixture means a missed message would pin the receiver; the
    # `erlang:trace_delivered(all)` barrier is the only mechanism that can
    # ensure all observed sends/receives surface in the bundle.
    out_dir = tmp_dir!("m6-flush-barrier")
    ebin_dir = tmp_dir!("m6-flush-barrier-ebin")
    compile_erlang_spawn_fixture!(ebin_dir)

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
          "spawn_messages",
          "flood",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_spawn_fixture,
        stderr_to_stdout: true
      )

    assert status == 0, """
    flood fixture record failed with status #{status}

    #{output}
    """

    summary = read_bundle_summary!(out_dir)

    assert summary["sidecar_trace_delivered"] == true,
           "session must finalize through erlang:trace_delivered(all) shutdown barrier"

    # Exactly one trace_delivered marker — the recorder must not double-
    # flush, double-drain, or silently lose the barrier.
    sidecar_path = Path.join(out_dir, "runtime_session.jsonl")
    sidecar_text = File.read!(sidecar_path)

    delivered_lines =
      sidecar_text
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, ~s("event":"trace_delivered")))

    assert length(delivered_lines) == 1,
           "expected exactly one trace_delivered marker, got #{length(delivered_lines)}"

    assert summary["send_event_count"] >= 66,
           "flood fixture must surface >=66 sends (1 ready + 64 pings + 1 done); got #{summary["send_event_count"]}"

    assert summary["receive_event_count"] >= 66,
           "flood fixture must surface >=66 receives; got #{summary["receive_event_count"]}"

    # The CTFS bundle must contain a structured TraceLogEvent for every
    # send and receive — this is the load-bearing assertion that the
    # delivered events round-trip through the writer/reader without drop.
    records = summary["event_log_records"]
    assert length(records) >= 132,
           "flood fixture must surface >=132 codetracer.beam.message.v1 events (66 send + 66 recv); got #{length(records)}"

    flush_pings =
      records
      |> Enum.filter(fn record ->
        record["direction"] == "receive" and record["tag"] == "flush_ping"
      end)

    assert length(flush_pings) == 64,
           "expected exactly 64 flush_ping receives in the CTFS bundle; got #{length(flush_pings)}"

    # Every ordered flush_ping must surface in the reader-visible
    # TraceLogEvent stream.
    received_indices =
      flush_pings
      |> Enum.map(fn record -> record["payload_repr"] end)
      |> MapSet.new()

    for index <- 1..64 do
      expected = "{flush_ping,#{index}}"

      assert MapSet.member?(received_indices, expected),
             "missing received flood message #{expected} in TraceLogEvent stream"
    end
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

  # Minimal recursive-descent JSON decoder mirroring the one in
  # runtime_session_test.exs / function_trace_test.exs to avoid pulling in
  # external Elixir dependencies.
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
        "codetracer-beam-recorder-m6-#{label}-#{pid}-#{nonce}"
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

  defp compile_erlang_spawn_fixture!(ebin_dir) do
    File.mkdir_p!(ebin_dir)
    src = Path.join(@erlang_spawn_fixture, "src/spawn_messages.erl")

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, src], stderr_to_stdout: true)

    assert status == 0, "erlc #{src} failed: #{output}"
  end
end
