# Module Filters

The recorder lets you scope what gets traced through three layers:

1. Application-level (`--include-app` / `--exclude-app`)
2. Module-level (`--include-module` / `--exclude-module`)
3. BEAM-level (`erlang:trace_pattern/3` dispatch — automatic;
   uninstrumented modules never reach the writer)

The flags are repeatable; they accumulate.

## Application filters

```sh
codetracer-beam-recorder record \
  --out-dir ct-traces \
  --include-app my_app \
  --include-app my_app_web \
  -- mix run -e "MyApp.main()"
```

Application filters apply at the manifest-discovery stage: the
recorder only emits `recorder_metadata/manifests/<module>.json`
for modules whose `application` field matches one of the
`--include-app` entries. Modules outside the allowlist still load
under the BEAM, but no trace pattern is installed on them.

`--exclude-app` is the inverse: every other application is
allowed.

## Module filters

```sh
codetracer-beam-recorder record \
  --out-dir ct-traces \
  --include-module Elixir.MyApp.Server \
  --exclude-module Elixir.Logger.Config \
  -- mix run -e "MyApp.main()"
```

Module names use the fully-qualified Elixir form (`Elixir.MyApp.Server`)
or the bare Erlang module name (`my_app_server`). Wildcards are not
supported in v1; if you need pattern-based filtering, list the
modules explicitly.

## BEAM-level dispatch

For every module the recorder decides to trace, it installs a
`local` match-spec via `erlang:trace_pattern({Module, Function,
Arity}, true, [local])`. Only those MFAs reach the tracer
process / native writer. Modules outside the recorder's allowlist
are never patterned and so never enter the recorder's hot path —
this is the practical performance budget.

## Send/receive

`--capture-messages true` enables `send` and `receive` trace
patterns globally. The send/receive filtering happens at the
recorder writer (`codetracer_session:install_message_trace_patterns/1`)
rather than per-module: once enabled, every BEAM process'
mailbox traffic is observed.

## Defaults

By default the recorder traces every module it can resolve a
manifest for under the working directory. The intended workflow is
"just record" without filters, and only reach for filters to
trim a bundle for a specific use case (e.g. Phoenix request
recording where you want only the application's modules, not the
Phoenix framework itself).
