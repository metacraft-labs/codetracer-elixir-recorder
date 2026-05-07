# CodeTracer BEAM Recorder Documentation

The CodeTracer BEAM recorder records Erlang and Elixir programs into the
CodeTracer CTFS trace bundle format. The bundle round-trips through the
same `NimTraceReaderHandle` that the rest of CodeTracer uses, so any
tool that consumes a CTFS bundle (the GUI, `ct print`, the VS Code
extension, the DAP bridge) can consume a recorder-produced bundle.

## Guides

- [`mix-integration.md`](mix-integration.md) — recording a Mix project.
- [`rebar3-integration.md`](rebar3-integration.md) — recording a Rebar3
  project.
- [`cli.md`](cli.md) — the standalone `codetracer-beam-recorder`
  command-line interface.
- [`source-maps.md`](source-maps.md) — sparse source-map artifacts and
  how the recorder copies sources into the bundle.
- [`module-filters.md`](module-filters.md) — `--include-module`,
  `--exclude-module`, and the runtime trace-pattern dispatch.
- [`ctfs-output.md`](ctfs-output.md) — what's inside a CTFS bundle and
  how to convert it with `ct print`.
- [`known-limitations.md`](known-limitations.md) — known gaps,
  including the M16 NIF deferral and the M15 GUI runtime CI gating.
- [`manifest-schema.md`](manifest-schema.md) — recorder metadata
  manifest schema (`codetracer.beam.module-manifest.v1`).
