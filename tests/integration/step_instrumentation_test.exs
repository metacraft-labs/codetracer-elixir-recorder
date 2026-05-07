ExUnit.start()

defmodule CodetracerBeamRecorder.StepInstrumentationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M8 verification: drives the real Erlang canonical fixture, the real
  generated-Erlang/Elixir source-map fixture, and the real tail-recursion
  fixture under `codetracer-beam-recorder` and asserts the M8 step
  instrumentation contract:

    * Step events appear at one event per distinct executable source line —
      matching the per-line oracle in
      `tests/goldens/canonical_flow/first-principles.org`. AST-node-level
      granularity (multiple steps per source line) is rejected; missing
      steps are rejected.
    * For generated Erlang sources that ship with a sparse source-map
      override, every step recorded for the generated module resolves to
      the original `.ex` source through the M7 source-map override path
      (`resolution: "source_map"`, `trace_copy_path` pointing at the
      copied original `.ex` file inside the trace bundle).
    * Tail-call positions are NOT wrapped: stdout and exit code of the
      uninstrumented and instrumented tail-recursion fixtures are
      identical, and the transformed-forms dump for the tail-recursive
      `count_down/2` clause has no expression after the recursive call
      (the tail call is the literal last expression of the clause body
      in the pretty-printed `erl_pp:form/1` output).

  All tests record real BEAM programs through the recorder binary and
  read back through the recorder's own `read-bundle-summary` subcommand
  (which wraps `NimTraceReaderHandle`), the on-disk runtime sidecar, and
  the on-disk transformed-forms dump under
  `recorder_metadata/transformed_forms/`.
  """

  @repo_root Path.expand("../..", __DIR__)
  @erlang_canonical Path.join(@repo_root, "test-programs/erlang/canonical_flow")
  @erlang_generated_source_map Path.join(
                                  @repo_root,
                                  "test-programs/erlang/generated_source_map"
                                )
  @erlang_tail_recursion Path.join(@repo_root, "test-programs/erlang/tail_recursion")

  test "e2e_instrumented_erlang_steps_match_golden" do
    out_dir = tmp_dir!("m8-canonical")
    ebin_dir = tmp_dir!("m8-canonical-ebin")
    compile_erlang_source!(ebin_dir, Path.join(@erlang_canonical, "src/canonical_flow.erl"))

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

    assert status == 0, "M8 canonical fixture record failed: #{output}"

    assert String.contains?(output, "94"),
           "fixture must produce the canonical result 94: #{output}"

    # Read the per-step location_ids the runtime emitted from the
    # transformed Erlang forms. Each `step` event is one execution of the
    # injected `codetracer_erlang_runtime:step/1` call.
    step_events = read_runtime_step_events!(out_dir)

    # Read the on-disk step-locations metadata the M8 instrumenter wrote
    # out alongside the manifest. This maps location_id -> {module,
    # source line, generated flag} so we can verify each runtime step
    # event lands on the expected source line.
    step_locations =
      Path.join([
        out_dir,
        "recorder_metadata",
        "step_locations",
        "src_canonical_flow.erl.step-locations.json"
      ])

    assert File.exists?(step_locations),
           "M8 instrumenter must emit per-source step location JSON at #{step_locations}"

    {locations_json, _rest} =
      step_locations
      |> File.read!()
      |> decode_json!()

    assert locations_json["schema"] == "codetracer.beam.step-locations.v1",
           "M8 step-locations sidecar must declare schema codetracer.beam.step-locations.v1"

    location_lookup =
      locations_json["locations"]
      |> Enum.map(fn loc -> {loc["id"], loc} end)
      |> Map.new()

    # The first-principles golden requires exactly one step per executed
    # source line of `compute/0` (lines 5..11) and `main/0` (lines 14..17).
    # The recorded order is determined by entrypoint `-s canonical_flow
    # main`: main/0 hits line 14 first (step 1, before the call to
    # compute/0), then control transfers into compute/0 which produces
    # steps at lines 5..11, then control returns to main/0 lines 15..17.
    expected_lines = [14, 5, 6, 7, 8, 9, 10, 11, 15, 16, 17]

    actual_lines =
      Enum.map(step_events, fn event ->
        location_id = event["location_id"]

        location =
          Map.get(location_lookup, location_id) ||
            flunk("""
            runtime emitted step for location_id #{location_id} but the
            instrumenter wrote no entry for it. Step-location JSON:
            #{File.read!(step_locations)}
            """)

        location["line"]
      end)

    # LOAD-BEARING: per-source-line granularity. If this assertion fires
    # the instrumenter emitted multiple steps per source line (an
    # AST-node-level walk) or missed lines (over-deduplicated), and the
    # M8 contract is broken.
    assert actual_lines == expected_lines, """
    M8 step sequence does not match the canonical_flow first-principles
    golden. Per-line step ordering oracle is

        #{inspect(expected_lines)}

    Recorded step lines were

        #{inspect(actual_lines)}

    Total recorded steps: #{length(actual_lines)}
    Expected total: #{length(expected_lines)}

    First-principles golden:
        tests/goldens/canonical_flow/first-principles.org §"Expected Step Sequence"

    Step events read from runtime sidecar (location_ids):
        #{inspect(Enum.map(step_events, & &1["location_id"]))}
    """

    # Cross-check via the trace-meta resolver order — the M7+M8 contract
    # requires every step location to resolve through one of the four
    # documented strategies, never through ad-hoc fallbacks.
    for line <- actual_lines do
      assert is_integer(line) and line > 0,
             "step lines must be real positive source lines; got #{inspect(line)}"
    end

    # Every step location must have its `generated` flag set to false
    # for this fixture (no Elixir source-map; pure Erlang source).
    for location_id <- Enum.map(step_events, & &1["location_id"]) do
      location = Map.get(location_lookup, location_id)

      assert location["generated"] == false,
             "canonical_flow steps must not be marked generated; location_id #{location_id} got #{inspect(location["generated"])}"
    end

    # Sanity: total step count equals the per-line oracle exactly.
    assert length(step_events) == length(expected_lines),
           "step event count #{length(step_events)} must equal per-line oracle #{length(expected_lines)}"

    # Sanity: the bundle summary surfaces the call-return contract from
    # M5, so this test does not regress to a step-only test that misses
    # call instrumentation.
    summary = read_bundle_summary!(out_dir)

    assert summary["call_count"] >= 2,
           "M8 must not regress M5 call/return tracing; got call_count=#{summary["call_count"]}"
  end

  test "e2e_instrumented_elixir_generated_steps_match_original_source" do
    out_dir = tmp_dir!("m8-generated")
    ebin_dir = tmp_dir!("m8-generated-ebin")

    compile_erlang_source!(
      ebin_dir,
      Path.join(@erlang_generated_source_map, "src/generated_bridge.erl")
    )

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
          "generated_bridge",
          "main",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_generated_source_map,
        stderr_to_stdout: true
      )

    assert status == 0, "M8 source-map fixture record failed: #{output}"

    assert String.contains?(output, "mapped-ok:42"),
           "fixture must produce the deterministic mapped-ok output: #{output}"

    # The original Elixir source must be copied into the trace bundle
    # under `files/lib/original_generated.ex` per M7 path normalization.
    original_copy = Path.join([out_dir, "files", "lib", "original_generated.ex"])

    assert File.exists?(original_copy),
           "trace bundle must contain copied original .ex source at #{original_copy}"

    # Every step event for the generated_bridge module must have its
    # location resolved through the source map, not through erl_anno.
    step_events = read_runtime_step_events!(out_dir)

    assert step_events != [],
           "generated_bridge fixture must produce at least one step event"

    step_locations_path =
      Path.join([
        out_dir,
        "recorder_metadata",
        "step_locations",
        "src_generated_bridge.erl.step-locations.json"
      ])

    assert File.exists?(step_locations_path),
           "M8 instrumenter must emit step-locations sidecar for generated_bridge"

    # The recorder writes the resolved (source-map-overridden) location
    # information into the per-module manifest, not into the
    # step-locations sidecar. Read the manifest to verify resolution.
    manifest_path =
      Path.join([out_dir, "recorder_metadata", "manifests", "generated_bridge.manifest.json"])

    {manifest_json, _} =
      manifest_path
      |> File.read!()
      |> decode_json!()

    locations_by_id =
      manifest_json["locations"]
      |> Enum.map(fn loc -> {loc["id"], loc} end)
      |> Map.new()

    # Every step event ID must exist in the manifest's locations list
    # AND its resolution must be `source_map`, AND its trace_copy_path
    # must point at a file that exists in the bundle. This is the M7+M8
    # source-map override contract end-to-end.
    for event <- step_events do
      location_id = event["location_id"]

      location =
        Map.get(locations_by_id, location_id) ||
          flunk("""
          step location_id #{location_id} from runtime sidecar is missing
          from the per-module manifest at #{manifest_path}.
          Manifest locations: #{inspect(Map.keys(locations_by_id))}
          """)

      # LOAD-BEARING: verifies generated_bridge step events resolve
      # through the M7 sparse source-map override to the original .ex
      # source. Without M7's resolver-order contract this would fall
      # back to erl_anno or module_file_fallback.
      assert location["resolution"] == "source_map",
             "M7+M8 contract: generated_bridge step locations must resolve via source_map; location_id #{location_id} got #{inspect(location["resolution"])}"

      bundle_path = Path.join(out_dir, location["trace_copy_path"])

      assert File.exists?(bundle_path),
             "source-map-resolved step location_id #{location_id} must point at a real bundled file: #{bundle_path}"

      assert location["trace_copy_path"] == "files/lib/original_generated.ex",
             "step trace_copy_path must point at the original Elixir source; got #{location["trace_copy_path"]}"

      assert location["build_path"] |> String.ends_with?("lib/original_generated.ex"),
             "step build_path must end at the original .ex source; got #{location["build_path"]}"
    end

    # Confirm the bundled original source is the real Elixir source, not
    # a placeholder.
    original_text = File.read!(original_copy)

    assert String.contains?(original_text, "defmodule OriginalGenerated"),
           "bundled original source at #{original_copy} must contain the real defmodule body"

    # Every step line recorded must be a valid 1-based source line into
    # the original `.ex` source. (lib/original_generated.ex has 16 lines.)
    original_line_count =
      original_text
      |> String.split("\n", trim: false)
      |> length()

    for event <- step_events do
      location = Map.fetch!(locations_by_id, event["location_id"])
      line = location["line"]

      assert is_integer(line) and line >= 1 and line <= original_line_count,
             "step line #{inspect(line)} must be a valid 1-based source line into lib/original_generated.ex (#{original_line_count} lines)"
    end
  end

  test "e2e_tail_recursion_semantics_preserved" do
    ebin_dir = tmp_dir!("m8-tail-ebin")
    compile_erlang_source!(ebin_dir, Path.join(@erlang_tail_recursion, "src/tail_recursion.erl"))

    # Step 1: run the uninstrumented fixture under raw `erl`. This is
    # the oracle for stdout + exit code.
    {uninstrumented_output, uninstrumented_status} =
      System.cmd(
        "erl",
        [
          "-noshell",
          "-pa",
          ebin_dir,
          "-s",
          "tail_recursion",
          "main",
          "-s",
          "init",
          "stop"
        ],
        stderr_to_stdout: true
      )

    assert uninstrumented_status == 0,
           "uninstrumented tail_recursion:main/0 must exit 0; got #{uninstrumented_status}: #{uninstrumented_output}"

    # The fixture prints `5000\n` from main/0; assert determinism.
    assert String.contains?(uninstrumented_output, "5000"),
           "uninstrumented tail_recursion fixture must print 5000: #{uninstrumented_output}"

    # Step 2: run the same source through the recorder, which compiles
    # an instrumented BEAM via the M8 abstract-forms pipeline and
    # records under the runtime session.
    out_dir = tmp_dir!("m8-tail-instrumented")

    {instrumented_output, instrumented_status} =
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
          "tail_recursion",
          "main",
          "-s",
          "init",
          "stop"
        ],
        cd: @erlang_tail_recursion,
        stderr_to_stdout: true
      )

    assert instrumented_status == 0,
           "instrumented tail_recursion:main/0 must exit 0; got #{instrumented_status}: #{instrumented_output}"

    # LOAD-BEARING #1: identical exit code between uninstrumented and
    # instrumented runs. The M8 contract is that instrumentation cannot
    # alter observable program behaviour for tail-call code.
    assert instrumented_status == uninstrumented_status,
           "M8 contract: instrumented tail-recursion exit code #{instrumented_status} must match uninstrumented exit code #{uninstrumented_status}"

    # The recorder emits its own banner stdout under `record`. Compare
    # the program's own output line-by-line by extracting numeric output
    # lines (the fixture prints `5000\n` from `main/0`).
    instrumented_program_lines =
      instrumented_output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.match?(&1, ~r/^[0-9]+$/))

    uninstrumented_program_lines =
      uninstrumented_output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.match?(&1, ~r/^[0-9]+$/))

    # LOAD-BEARING #2: identical numeric stdout. If instrumentation
    # corrupted state across the tail-recursive `count_down/2` (e.g. by
    # turning the tail call into a non-tail wrapped call), the fixture
    # would print a different number or fail the `5000 =:= Result`
    # assertion before reaching `io:format/2`.
    assert instrumented_program_lines == uninstrumented_program_lines,
           "M8 contract: instrumented numeric stdout #{inspect(instrumented_program_lines)} must equal uninstrumented numeric stdout #{inspect(uninstrumented_program_lines)}"

    # Step 3: read the transformed-forms dump and verify the
    # `count_down/2` recursive clause's tail call has no post-call
    # wrapper. This is the M8 "no post-tail wrappers" contract.
    transformed_path =
      Path.join([
        out_dir,
        "recorder_metadata",
        "transformed_forms",
        "src_tail_recursion.erl.transformed.erl"
      ])

    assert File.exists?(transformed_path),
           "M8 transformed-forms dump must exist at #{transformed_path}"

    transformed_text = File.read!(transformed_path)

    assert String.contains?(
             transformed_text,
             "%% codetracer transformed forms dump format: erl_pp:form/1 pretty-printed Erlang source"
           ),
           "transformed-forms dump must declare its format header (erl_pp:form/1 pretty-printed Erlang source)"

    # Find the recursive `count_down/2` clause body. The recursive
    # clause is `count_down(N, Acc) when N > 0 -> ... count_down(N - 1,
    # Acc + 1).`. After M8 instrumentation the body must end with the
    # bare recursive call followed by `.` (clause terminator) — there
    # must be NO trailing expression that consumes the recursive call's
    # return value. If there were a wrapper it would look like e.g.
    # `Result = count_down(...), codetracer_erlang_runtime:step(...),
    # Result.` or `begin count_down(...), ... end.`.
    refute String.contains?(transformed_text, "count_down(N - 1, Acc + 1),"),
           """
           M8 contract: tail call `count_down(N - 1, Acc + 1)` MUST be the
           last expression of its clause body. The transformed-forms dump
           contains a comma after the tail call, which means the
           instrumenter inserted a post-tail expression (a wrapper) and
           broke the no-post-tail-call contract. Dump:

           #{transformed_text}
           """

    # Stronger structural check: parse the transformed clause body and
    # assert it ends with the recursive call literal. This catches
    # wrappers that don't add a comma (e.g. `begin count_down(...) end`
    # would still be a wrapper).
    refute String.match?(transformed_text, ~r/begin\s+count_down\(N - 1, Acc \+ 1\)/),
           """
           M8 contract: the recursive `count_down(N - 1, Acc + 1)` tail
           call MUST NOT be wrapped in a `begin ... end` block. A `begin`
           wrapper consumes the tail call's return value through the
           block's last expression and breaks tail-call optimisation.

           #{transformed_text}
           """

    # The simplest positive assertion: the recursive clause body must
    # contain the literal sequence `step(...), count_down(N - 1, Acc +
    # 1).` (period, not comma) — proving the step marker is BEFORE the
    # tail call and the tail call is the literal last expression of
    # the clause body.
    assert String.match?(
             transformed_text,
             ~r/count_down\(N, Acc\) when N > 0 ->\s*codetracer_erlang_runtime:step\(\d+\)(?:,\s*codetracer_erlang_runtime:bind_many\(\[[^\]]*\]\))?,\s*count_down\(N - 1, Acc \+ 1\)\./
           ),
           """
           M8 contract: the recursive count_down/2 clause must take the
           shape

               count_down(N, Acc) when N > 0 ->
                   codetracer_erlang_runtime:step(<id>),
                   [optional clause-entry binding],
                   count_down(N - 1, Acc + 1).   %% period, NOT comma

           Pre-tail step marker only; recursive call is the literal last
           expression of the clause body. Actual transformed forms:

           #{transformed_text}
           """

    # Also assert the same shape for the second clause `count_down(0,
    # Acc) -> Acc.` — its tail expression is the bare variable `Acc`
    # and there must be no post-`Acc` expression.
    assert String.match?(
             transformed_text,
             ~r/count_down\(0, Acc\) ->\s*codetracer_erlang_runtime:step\(\d+\)(?:,\s*codetracer_erlang_runtime:bind_many\(\[[^\]]*\]\))?,\s*Acc;/
           ),
           """
           M8 contract: the base `count_down(0, Acc) -> Acc;` clause
           must have its `Acc` return as the literal last expression.
           Pre-step marker only. Actual transformed forms:

           #{transformed_text}
           """

    # Determinism guard: re-run the instrumented fixture five times and
    # require identical stdout/exit-code each time. This catches
    # non-determinism introduced by the instrumentation (e.g. a step
    # ordering that depends on scheduling).
    for run <- 1..5 do
      run_out_dir = tmp_dir!("m8-tail-determinism-#{run}")

      {run_output, run_status} =
        System.cmd(
          recorder_binary!(),
          [
            "record",
            "--out-dir",
            run_out_dir,
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir,
            "-s",
            "tail_recursion",
            "main",
            "-s",
            "init",
            "stop"
          ],
          cd: @erlang_tail_recursion,
          stderr_to_stdout: true
        )

      assert run_status == uninstrumented_status,
             "M8 determinism: run #{run} exit code #{run_status} must equal uninstrumented exit code #{uninstrumented_status}"

      run_program_lines =
        run_output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.match?(&1, ~r/^[0-9]+$/))

      assert run_program_lines == uninstrumented_program_lines,
             "M8 determinism: run #{run} numeric stdout #{inspect(run_program_lines)} must equal #{inspect(uninstrumented_program_lines)}"
    end
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

  # Read every `step` event from the runtime session sidecar, in order.
  # Each event has the shape `{"event":"step","pid":...,"thread_id":...,
  # "location_id":<integer>}`.
  defp read_runtime_step_events!(out_dir) do
    sidecar_path = Path.join(out_dir, "runtime_session.jsonl")

    text = File.read!(sidecar_path)

    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case decode_json!(line) do
        {%{"event" => "step"} = event, _rest} -> [event]
        _ -> []
      end
    end)
  end

  defp compile_erlang_source!(ebin_dir, source_path) do
    File.mkdir_p!(ebin_dir)

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, source_path], stderr_to_stdout: true)

    assert status == 0, "erlc #{source_path} failed: #{output}"
  end

  defp tmp_dir!(label) do
    nonce = System.unique_integer([:positive])
    pid = System.system_time(:nanosecond)

    path =
      Path.join(
        System.tmp_dir!(),
        "codetracer-beam-recorder-m8-#{label}-#{pid}-#{nonce}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  # Minimal recursive-descent JSON decoder — mirrors the helper used in
  # the other M*-integration tests so the fixtures work in plain `elixir`
  # without external dependencies.
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
end
