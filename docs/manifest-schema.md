# Elixir/Erlang Recorder Manifest Schema

M7 defines the recorder metadata contract as JSON v1.

## Module Manifest

Manifest files live under `recorder_metadata/manifests/*.manifest.json`.
The schema identifier is `codetracer.beam.module-manifest.v1`, and the v1
encoding decision is JSON. JSON is intentionally used for the first contract
because the runtime can load the exact files into `persistent_term`, tests can
verify them without generated baselines, and the files remain readable while
the abstract-form instrumentation contract is still evolving.

Top-level fields:

- `schema`: `codetracer.beam.module-manifest.v1`
- `encoding`: `json`
- `manifest_id`: stable per-module identifier, currently
  `beam-manifest-v1:<module>`
- `module`: module identity, source language, absolute build path,
  project-relative path, and trace copy path
- `functions`: function keys, arities, entry location IDs, clause IDs, and
  traceability flags
- `locations`: stable location IDs resolved to source metadata
- `clauses`: clause IDs linked back to function keys and location IDs
- `variable_slot_templates`: runtime-visible argument slots for the current
  M7 contract
- `traceable_mfas`: MFAs enabled for runtime tracing
- `source_maps`: copied source-map artifacts relevant to this module

## Sparse Source Map

Source-map files live under `recorder_metadata/source_maps/*.json`.
The schema identifier is `codetracer.beam.sourcemap.v1`.

Each file maps generated Erlang file/line/column points to original
source-language file/line/column points:

- `generated_path`: absolute build-time path after recorder normalization
- `original_path`: absolute build-time path after recorder normalization
- `mappings`: sparse exact-line mappings. A `null` generated column matches
  any column for that generated line.

## Resolver Order

Source locations resolve in this order:

1. `source_map`
2. `erl_anno`
3. `module_file_fallback`
4. `unknown_generated_fallback`

Trace copies use `files/<project-relative-path>`. Compatibility source copies
are also kept under `source_map/` for older M1-M6 tests.
