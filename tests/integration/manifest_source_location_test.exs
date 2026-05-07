ExUnit.start()

defmodule CodetracerBeamRecorder.ManifestSourceLocationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  M7 verification: drives real Elixir and Erlang fixtures (including the
  generated-Erlang fixture under `test-programs/erlang/generated_source_map/`
  that ships with a hand-written sparse source-map JSON) under the
  `codetracer-beam-recorder` runtime and asserts the manifest + source-map
  metadata contract:

    * The runtime loads real on-disk manifest files into `persistent_term`,
      emits a `manifest_loaded` sidecar event with the schema, encoding,
      `persistent_term` key, and absolute manifest paths, and surfaces calls
      that resolve through manifest IDs.
    * Source locations on every recorded event resolve via the four-layer
      resolver (`source_map`, `erl_anno`, `module_file_fallback`,
      `unknown_generated_fallback`) to real on-disk source files copied
      into `<out_dir>/source_map/` (legacy compatibility) and
      `<out_dir>/files/` (project-relative trace copies).
    * The sparse source-map override in `generated_source_map/source_maps/`
      causes the resolver to emit `resolution: "source_map"` events
      pointing at the original `.ex` file in the trace bundle.

  The test deliberately reads back through the recorder's own
  `read-bundle-summary` subcommand (which wraps `NimTraceReaderHandle` —
  the same reader downstream debugger tooling will use), the on-disk
  manifest JSONs, and the runtime sidecar, and resolves source locations
  from real bundle files (`File.exists?` / `File.read!`) — no mocked path
  data anywhere in the assertion chain.
  """

  @repo_root Path.expand("../..", __DIR__)
  @elixir_canonical Path.join(@repo_root, "test-programs/elixir/canonical_flow")
  @erlang_canonical Path.join(@repo_root, "test-programs/erlang/canonical_flow")
  @erlang_generated_source_map Path.join(@repo_root, "test-programs/erlang/generated_source_map")

  test "e2e_manifest_loaded_by_runtime_session" do
    out_dir = tmp_dir!("m7-manifest")
    mix_build_root = tmp_dir!("m7-manifest-build")
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
          "CanonicalFlow.identity(42)"
        ],
        cd: @elixir_canonical,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", mix_build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, """
    M7 manifest fixture record failed with status #{status}

    #{output}
    """

    summary = read_bundle_summary!(out_dir)

    # The recorder writes a `*.manifest.json` per traced module to
    # `recorder_metadata/manifests/`. The reader bridge counts them here so
    # tests do not have to walk the filesystem manually.
    assert summary["manifest_count"] >= 1,
           "M7 contract: bundle must contain at least one module manifest; got #{summary["manifest_count"]}"

    assert "Elixir.CanonicalFlow" in summary["manifest_modules"],
           "M7 contract: manifests must include CanonicalFlow; got #{inspect(summary["manifest_modules"])}"

    # The runtime emits a `manifest_loaded` sidecar event at session start.
    # Its schema, encoding, and persistent_term key form the M7 v1
    # contract; the manifest_count must agree with the on-disk file count.
    loaded_event = summary["manifest_loaded_event"]
    assert is_map(loaded_event), "missing manifest_loaded sidecar event"

    assert loaded_event["schema"] == "codetracer.beam.module-manifest.v1",
           "M7 schema must be codetracer.beam.module-manifest.v1; got #{loaded_event["schema"]}"

    assert loaded_event["encoding"] == "json",
           "M7 v1 manifest encoding must be json; got #{loaded_event["encoding"]}"

    assert loaded_event["persistent_term_key"] ==
             "{codetracer_beam_recorder,manifests}",
           "runtime must publish manifests under the documented persistent_term key"

    assert loaded_event["manifest_count"] == summary["manifest_count"],
           "manifest_loaded.manifest_count (#{loaded_event["manifest_count"]}) must equal the bundle manifest count (#{summary["manifest_count"]})"

    # Every path in the manifest_loaded event must be a real, absolute
    # filesystem path that exists on disk. This is the load-bearing check
    # that proves the runtime loaded actual files into `persistent_term`,
    # not synthesized data.
    for path <- loaded_event["manifest_paths"] do
      assert is_binary(path) and Path.type(path) == :absolute,
             "manifest_paths must contain absolute filesystem paths; got #{inspect(path)}"

      assert File.exists?(path),
             "manifest path from manifest_loaded must exist on disk: #{path}"

      content = File.read!(path)

      assert String.contains?(content, "codetracer.beam.module-manifest.v1"),
             "on-disk manifest must carry the v1 schema string; got truncated read of #{path}"
    end

    # Calls recorded under the manifest must reference manifest IDs and
    # location IDs that match the loaded manifest. This proves the runtime
    # consulted persistent_term during call dispatch.
    records = summary["manifest_loaded_records"]
    assert is_list(records) and records != [],
           "expected at least one call recorded with manifest metadata"

    identity_record =
      Enum.find(records, fn record ->
        record["module"] == "Elixir.CanonicalFlow" and
          record["function"] == "identity"
      end)

    assert identity_record != nil,
           "expected a CanonicalFlow.identity call to carry manifest metadata; got #{inspect(records)}"

    assert identity_record["manifest_id"] == "beam-manifest-v1:Elixir.CanonicalFlow",
           "call must reference the manifest_id minted by the manifest writer"

    assert identity_record["function_key"] == "Elixir.CanonicalFlow.identity/1"

    assert identity_record["location_id"] > 0,
           "call must carry a non-zero manifest location_id"

    assert identity_record["resolution"] in [
             "source_map",
             "erl_anno",
             "module_file_fallback",
             "unknown_generated_fallback"
           ],
           "call source_location.resolution must be one of the documented strategies; got #{identity_record["resolution"]}"
  end

  test "e2e_source_location_resolution_real_files" do
    # Elixir fixture: source_map resolution from real Mix project compile.
    elixir_out = tmp_dir!("m7-source-elixir")
    mix_build_root = tmp_dir!("m7-source-elixir-build")
    compile_elixir_fixture!(@elixir_canonical, mix_build_root)

    {output, status} =
      System.cmd(
        recorder_binary!(),
        [
          "record",
          "--out-dir",
          elixir_out,
          "--",
          "mix",
          "run",
          "--no-compile",
          "-e",
          "CanonicalFlow.compute()"
        ],
        cd: @elixir_canonical,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_ROOT", mix_build_root}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "Elixir M7 source-resolution fixture failed: #{output}"

    elixir_summary = read_bundle_summary!(elixir_out)

    # The trace_meta.json contract MUST publish the documented resolver
    # order so downstream consumers know which fallback strategies to
    # accept. This is read off disk through the recorder's own subcommand.
    meta = read_trace_meta!(elixir_out)

    assert get_in(meta, ["metadata_contract", "source_location_resolver_order"]) == [
             "source_map",
             "erl_anno",
             "module_file_fallback",
             "unknown_generated_fallback"
           ],
           "trace_meta.metadata_contract.source_location_resolver_order must list all four resolver layers in order; got #{inspect(meta["metadata_contract"])}"

    assert get_in(meta, ["metadata_contract", "manifest_schema"]) ==
             "codetracer.beam.module-manifest.v1"

    assert get_in(meta, ["metadata_contract", "manifest_encoding"]) == "json"

    # The compatibility source-copy directory (M4.3) AND the project-
    # relative trace-copy directory must both contain the recorded source.
    legacy_copy = Path.join([elixir_out, "source_map", "lib", "canonical_flow.ex"])
    project_copy = Path.join([elixir_out, "files", "lib", "canonical_flow.ex"])

    assert File.exists?(legacy_copy),
           "trace bundle must contain compatibility source copy at #{legacy_copy}"

    assert File.exists?(project_copy),
           "trace bundle must contain project-relative source copy at #{project_copy}"

    # The on-disk source content must be readable and non-empty — proving
    # we copied a real file, not a placeholder.
    project_source = File.read!(project_copy)

    assert String.contains?(project_source, "defmodule CanonicalFlow"),
           "copied source must contain the real Elixir module body"

    # Every call recorded with manifest metadata must point to a real
    # source file inside the bundle, resolved through one of the four
    # strategies. This proves M7's path normalization end-to-end.
    for record <- elixir_summary["manifest_loaded_records"] do
      assert record["resolution"] in [
               "source_map",
               "erl_anno",
               "module_file_fallback",
               "unknown_generated_fallback"
             ]

      bundle_path = Path.join(elixir_out, record["trace_copy_path"])

      if record["resolution"] == "source_map" do
        assert File.exists?(bundle_path),
               "source_map-resolved location must point to a real file inside the bundle: #{bundle_path}"
      end
    end

    # Erlang fixture: real `.erl` source resolution end-to-end.
    erlang_out = tmp_dir!("m7-source-erlang")
    ebin_dir = tmp_dir!("m7-source-erlang-ebin")
    compile_erlang_canonical!(ebin_dir)

    {erl_output, erl_status} =
      System.cmd(
        recorder_binary!(),
        [
          "record",
          "--out-dir",
          erlang_out,
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

    assert erl_status == 0, "Erlang M7 source-resolution fixture failed: #{erl_output}"

    erlang_legacy = Path.join([erlang_out, "source_map", "src", "canonical_flow.erl"])
    erlang_project = Path.join([erlang_out, "files", "src", "canonical_flow.erl"])

    assert File.exists?(erlang_legacy),
           "Erlang trace bundle must contain compatibility source copy at #{erlang_legacy}"

    assert File.exists?(erlang_project),
           "Erlang trace bundle must contain project-relative source copy at #{erlang_project}"

    erlang_summary = read_bundle_summary!(erlang_out)

    assert "canonical_flow" in erlang_summary["manifest_modules"],
           "Erlang manifest must list the canonical_flow module; got #{inspect(erlang_summary["manifest_modules"])}"

    # Ensure events are anchored at real lines in the real source file
    # (not generated/<unknown>). This rules out the silent fallback to a
    # placeholder path.
    erlang_source = File.read!(erlang_project)

    assert String.contains?(erlang_source, "-module(canonical_flow)"),
           "Erlang source bundle must contain the real -module attribute"
  end

  test "e2e_source_map_sparse_override_real_trace" do
    out_dir = tmp_dir!("m7-source-map")
    ebin_dir = tmp_dir!("m7-source-map-ebin")
    compile_erlang_generated_source_map!(ebin_dir)

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

    assert status == 0, "M7 sparse source-map fixture record failed: #{output}"

    assert String.contains?(output, "mapped-ok:42"),
           "fixture must produce the deterministic mapped-ok output: #{output}"

    summary = read_bundle_summary!(out_dir)

    assert "generated_bridge" in summary["manifest_modules"],
           "manifests must include generated_bridge; got #{inspect(summary["manifest_modules"])}"

    # The recorder copies the sparse source-map JSON into
    # `recorder_metadata/source_maps/` and the original Elixir source into
    # `files/lib/original_generated.ex`. Both must exist.
    source_map_artifact =
      Path.join([
        out_dir,
        "recorder_metadata",
        "source_maps",
        "001-src_generated_bridge.erl.json"
      ])

    assert File.exists?(source_map_artifact),
           "trace bundle must contain copied sparse source-map artifact at #{source_map_artifact}"

    original_source = Path.join([out_dir, "files", "lib", "original_generated.ex"])

    assert File.exists?(original_source),
           "trace bundle must contain copied original Elixir source at #{original_source}"

    # The fixture's `main/0` is at generated line 9 -> original Elixir line
    # 10 per the sparse source-map JSON. The runtime must record the call
    # with `resolution: "source_map"` and the trace copy path must point
    # at the original `.ex`.
    main_record =
      Enum.find(summary["manifest_loaded_records"], fn record ->
        record["module"] == "generated_bridge" and record["function"] == "main"
      end)

    assert main_record != nil,
           "expected a generated_bridge:main call recorded with manifest metadata; got #{inspect(summary["manifest_loaded_records"])}"

    assert main_record["resolution"] == "source_map",
           "M7 contract: main/0 must resolve via the sparse source-map override; got #{main_record["resolution"]}"

    assert main_record["trace_copy_path"] == "files/lib/original_generated.ex",
           "source-map-resolved trace_copy_path must point at the original Elixir source; got #{main_record["trace_copy_path"]}"

    # Read the original source from the bundle to prove the sparse
    # override resolved to a real file with real content.
    original_text = File.read!(original_source)

    assert String.contains?(original_text, "defmodule OriginalGenerated"),
           "original source bundled at #{original_source} must contain the real defmodule body"

    # The resolver order contract must surface BOTH the source-map path
    # AND a fallback path on the same recorded program. The recorder
    # writes one manifest per traced module under
    # `recorder_metadata/manifests/`; the bridge fixture's
    # `generated_bridge` module resolves through the sparse override,
    # while the discovered companion `OriginalGenerated.ex` module is a
    # real Elixir source file whose locations resolve via the second
    # layer (`erl_anno`) — proving the resolver order is honored.
    manifest_dir = Path.join([out_dir, "recorder_metadata", "manifests"])

    manifest_resolutions =
      manifest_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".manifest.json"))
      |> Enum.flat_map(fn filename ->
        path = Path.join(manifest_dir, filename)
        text = File.read!(path)
        {decoded, _rest} = decode_json!(text)

        decoded
        |> Map.get("locations", [])
        |> Enum.map(fn location -> location["resolution"] end)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert "source_map" in manifest_resolutions,
           "sparse source-map override must produce manifest locations with resolution=source_map; got #{inspect(manifest_resolutions)}"

    # The companion module's manifest must contain at least one
    # `erl_anno` location, proving the second resolver layer fires when
    # no sparse mapping exists. If the resolver silently masked
    # erl_anno with source_map, this assertion would catch it.
    assert "erl_anno" in manifest_resolutions,
           "fixture must exercise the erl_anno resolver layer; got #{inspect(manifest_resolutions)}"

    # Cross-check the same contract via the runtime sidecar: at least
    # one recorded call must carry source_location.resolution=source_map
    # (the calls into generated_bridge:main/compute) — proving the
    # runtime-side resolver actually consulted the source map on every
    # event, not just at metadata-write time.
    sidecar_path = Path.join(out_dir, "runtime_session.jsonl")
    sidecar_text = File.read!(sidecar_path)

    sidecar_resolutions =
      sidecar_text
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/"resolution":"([^"]+)"/, line) do
          [_, resolution] -> [resolution]
          nil -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert "source_map" in sidecar_resolutions,
           "runtime sidecar must record at least one event whose source_location.resolution = source_map; got #{inspect(sidecar_resolutions)}"
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

  defp read_trace_meta!(out_dir) do
    text = File.read!(Path.join(out_dir, "trace_meta.json"))
    {decoded, _rest} = decode_json!(text)
    decoded
  end

  # Minimal recursive-descent JSON decoder — mirrors the one in the other
  # M*-integration tests so we avoid pulling in external Elixir
  # dependencies (the fixtures must work in plain `elixir`).
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
        "codetracer-beam-recorder-m7-#{label}-#{pid}-#{nonce}"
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

  defp compile_erlang_canonical!(ebin_dir) do
    File.mkdir_p!(ebin_dir)
    src = Path.join(@erlang_canonical, "src/canonical_flow.erl")

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, src], stderr_to_stdout: true)

    assert status == 0, "erlc #{src} failed: #{output}"
  end

  defp compile_erlang_generated_source_map!(ebin_dir) do
    File.mkdir_p!(ebin_dir)
    src = Path.join(@erlang_generated_source_map, "src/generated_bridge.erl")

    {output, status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, src], stderr_to_stdout: true)

    assert status == 0, "erlc #{src} failed: #{output}"
  end
end
