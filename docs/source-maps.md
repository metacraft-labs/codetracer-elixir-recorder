# Source Maps

The recorder ships sources alongside the trace bundle so the reader
can navigate from `call` events to the originating source line
without needing the build to still be on disk. Two artifacts make
this work: the `source_map/` directory (a copy of the recorded
sources) and per-module sparse source-map JSON files.

## `source_map/`

Every source file the recorder traced is copied into
`<bundle>/source_map/`. Paths are normalized to project-relative
form (`lib/my_app/server.ex`, `src/my_app.erl`). The
`runtime_session.jsonl` sidecar records each call event with a
`trace_copy_path` that points into this tree.

## Sparse source-map JSON

For Elixir, the recorder reads the sparse source maps emitted by
the Mix integration (`compile.codetracer` task). They map each
generated function key
(`Elixir.MyApp.Server.handle_call/3:clause-1`) to the originating
line in the canonical source file. The reader uses these to
resolve `clause_id` -> source line without re-parsing the abstract
forms at read time.

For Erlang, the source maps come from `erl_anno`: the recorder
reads the BEAM file's `debug_info` chunk and emits a sparse
source-map JSON file alongside the manifest. This works for any
project compiled with `+debug_info` (the Rebar3 integration
defaults to `+debug_info` under the `codetrace` profile).

## Forwarding extra source maps

Pass `--source-map PATH` (repeatable) to the recorder to seed
extra source-map JSON files. The map is reloaded when the bundle
is opened so adding a source map to an already-recorded bundle is
not necessary; the seeding is for projects that generate sources
through a stage the recorder did not observe (e.g. macro
expansion via a remote build, or a generated-Erlang stage like
LFE).

## Resolution semantics

Each `call` event in the sidecar carries:

- `manifest_id` — `beam-manifest-v1:<module>` reference into
  `recorder_metadata/manifests/<module>.manifest.json`.
- `function_key` — stable per-function identifier (the same key
  used by the source map).
- `location_id` — opaque per-clause id; resolved against the
  manifest to a `(file, line, col)` triple at read time.
- `source_location` — pre-resolved `{build_path, trace_copy_path,
  line, column, resolution}` so the reader does not need to
  resolve `location_id` itself.

The `resolution` field surfaces which source-of-truth resolved
the location: `erl_anno` (BEAM debug_info), `elixir_macro`
(macro-expanded line range), or `unknown` (no source map; the
reader falls back to the function name).
