# Mix Integration

`codetracer-beam-recorder` ships with a Mix task that records a Mix
project end-to-end. The task is delivered as a Hex package
(`codetracer_beam_recorder`) that you add to your project's
`deps/0` list under a dedicated profile.

## 1. Add the dependency

```elixir
# mix.exs
def project do
  [
    app: :my_app,
    version: "0.1.0",
    elixir: "~> 1.16",
    deps: deps()
  ]
end

defp deps do
  [
    {:codetracer_beam_recorder, "~> 0.1", only: [:codetrace]}
  ]
end
```

The `only: [:codetrace]` clause means production builds never link
against the recorder. Run the task through the dedicated environment:

```sh
MIX_ENV=codetrace mix deps.get
MIX_ENV=codetrace mix codetracer.record --out-dir ct-traces -e "MyApp.main()"
```

## 2. Run the recorder

The `mix codetracer.record` task wraps the standalone
`codetracer-beam-recorder` binary. The binary handles real BEAM
launching, source copying, and CTFS write-out; the Mix task wires
the project's source root, build artifacts, and source maps.

Common flags:

```text
mix codetracer.record \
  --out-dir ct-traces \
  --include-app my_app \
  --exclude-module Logger.Config \
  -e "MyApp.main()"
```

- `--out-dir DIR` — destination CTFS bundle. Defaults to
  `ct-traces/`. The directory is created if missing.
- `--include-app APP` / `--exclude-app APP` — limit recording to
  specific OTP applications. Multiple flags allowed.
- `--include-module MODULE` / `--exclude-module MODULE` — module-
  level filters. Module names are the fully-qualified Elixir form
  (`MyApp.Server`), no `:` prefix.
- `--capture-messages true|false` — toggle send/receive trace
  events. Default `false`.
- `--value-max-depth`, `--value-max-sequence-items`,
  `--value-max-binary-bytes`, `--value-max-map-pairs`,
  `--value-max-string-bytes` — bound the term encoder. These
  are safety knobs for stress runs.
- `-e EXPR` / `--eval EXPR` — Elixir expression to drive. Equivalent
  to `mix run -e EXPR`. Optional; if omitted, the recorder runs the
  default Mix task.

## 3. Verify the bundle

The recorder writes the bundle as a directory with a `.ct` file at
the root, a `runtime_session.jsonl` sidecar, a `recorder_metadata/`
tree (per-module manifests), and a `source_map/` copy of the
recorded source files. Verify the bundle loads through the
canonical reader:

```sh
codetracer-beam-recorder read-bundle-summary --bundle ct-traces
```

The single-line JSON output reports thread lifecycle counts, sidecar
event counts, and the final `trace_delivered` status. The same
output is what the integration tests assert on.

## 4. Troubleshooting

- **"could not find application file"** — Mix is trying to start
  the application before `mix run` evaluates `-e`. Either drop the
  `application/0` `mod:` clause from your `mix.exs`, or pass
  `--no-start`.
- **No `call` events recorded** — the recorder's source-file
  parser scans `lib/`, `src/`, and `test/` under the working
  directory. If your sources live elsewhere, run
  `cd <project_root>` before `mix codetracer.record` so the working
  directory matches the source root.
- **Empty `source_map/` directory** — the recorder copies sources
  reachable from the discovered `--source-dir` set. Add the build
  output (`_build/<env>/lib/<app>/ebin`) to `MIX_BUILD_ROOT` so the
  recorder finds the compiled `.beam` files alongside their source.
