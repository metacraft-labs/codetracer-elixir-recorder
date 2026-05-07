# Standalone CLI

`codetracer-beam-recorder` is the standalone CLI binary that records
any BEAM-targeted program (Erlang or Elixir, raw or via a build tool)
and produces a CTFS trace bundle. The Mix and Rebar3 integrations are
thin wrappers around this binary; you can also drive it directly when
your build system is something other than Mix or Rebar3.

## Subcommands

```text
codetracer-beam-recorder record [OPTIONS] -- <command> [args]
codetracer-beam-recorder compile [OPTIONS] --source-dir PATH
codetracer-beam-recorder instrument [OPTIONS] --source-dir PATH
codetracer-beam-recorder read-bundle-summary --bundle DIR
codetracer-beam-recorder --version
codetracer-beam-recorder --help
```

The most common invocation is `record`, which wraps a real BEAM
target. Anything after `--` is the launch command line.

## `record`

```text
codetracer-beam-recorder record [OPTIONS] -- <command> [args]
```

Options:

```text
--out-dir DIR              CTFS bundle destination (required, or
                           CODETRACER_BEAM_RECORDER_OUT_DIR=DIR)
--source-dir PATH          BEAM source directory; repeatable
--source-map PATH          sparse source-map JSON file or directory;
                           repeatable
--include-app APP          only record events from this OTP
                           application; repeatable
--exclude-app APP          drop events from this OTP application;
                           repeatable
--include-module M         only record events from this module;
                           repeatable
--exclude-module M         drop events from this module; repeatable
--capture-messages true|false   send/receive event toggle
                                (default: false)
--tracer-backend process|native CodeTracer tracer backend
                                (default: process; see M16 docs)
--tracer-queue-limit N     native-backend queue ceiling (default
                           65536)
--tracer-overflow-policy block|drop   native-backend backpressure
                                       policy (default: block)
--value-max-depth N        recursion bound for the term encoder
--value-max-sequence-items N
--value-max-binary-bytes N
--value-max-map-pairs N
--value-max-string-bytes N
```

Environment-variable equivalents: every flag has a
`CODETRACER_BEAM_RECORDER_<UPPER_NAME>` env var (replace `-` with
`_`). The flag wins if both are set. Setting
`CODETRACER_BEAM_RECORDER_DISABLED=1` makes the wrapper exec the
target program without recording — useful for one-off CI debugging.

The recorder discovers sources by walking `lib/`, `src/`, and
`test/` under the working directory unless `--source-dir` is given.

## `read-bundle-summary`

Loads a recorded bundle through the same `NimTraceReaderHandle`
the GUI uses and emits a one-line JSON summary covering:

- the `.ct` file detected (`status`, `format`, `reader`)
- thread lifecycle counts (root and total)
- sidecar event counts (calls, returns, exceptions, sends,
  receives, process spawn/exit)
- `trace_delivered` status (was the runtime session finalized
  cleanly?)
- per-fixture decoded message records (sender, recipient,
  payload schema)

This is the same projection the integration tests assert on.

## Exit codes

- `0` — recording succeeded and the target program exited 0.
- non-zero — the recorder propagates the target's exit code so a
  recording driven via `--` does not silently swallow target
  failures.
