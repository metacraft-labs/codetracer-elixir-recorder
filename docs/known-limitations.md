# Known Limitations

This document collects the known gaps in the v1 BEAM recorder. Each
item is a feature that intentionally landed `implementation_partial`
in the milestones plan with a `:scope_deferred:` rationale; nothing
here is a silent regression. The follow-up work for each item is
tracked in [BEAM-Materialized-Trace-Recorder.milestones.org](
../../codetracer-specs/Planned-Work/BEAM-Materialized-Trace-Recorder.milestones.org).

## M16: optimized native tracer is a gen_server, not a real `erl_tracer` NIF

The M16 native backend (`--tracer-backend native`) ships as an Erlang
`gen_server` writer process rather than an `erl_tracer` NIF callback
module loaded via `erlang:load_nif/2`. This satisfies the M16
observable contract — atomic sequence ordering, parity with the
process backend, explicit overflow diagnostics, and a
`trace_delivered`-aware shutdown drain — but it is not the
sub-microsecond per-event NIF the spec aims for.

**What works:**

- `--tracer-backend native` runs and writes a sidecar with
  `"backend":"native"` markers.
- `counters`-based atomic sequence numbers stamped on every event.
- Explicit `block` (default) / `drop` overflow policy.
- `erlang:trace_delivered/1` shutdown barrier preserved.
- Native and process backends produce equivalent event sets through
  the reader (M16 parity test).

**What's deferred:**

- Real `erl_tracer` NIF callback module (Rust + `rustler`).
- `enabled_trace`, `enabled_call`, `enabled_send`, `enabled_receive`
  per-event filter callbacks (these require the NIF).
- Background C writer thread via `enif_thread_create`.
- `step` and `bind_many` events under native mode (M8/M9
  instrumentation paths only emit under process mode).

The M16 public API surface (`start_link/1`, `stop/2`,
`install_root_trace/2`, `event_count/0`, `dropped_count/0`,
`overflow_status/0`) is the seam the future NIF will replace
without churning `codetracer_session`.

## M15: GUI runtime CI gating

The M15 UI + VS Code smoke fixtures exercise the GUI surface against a
recorder-produced bundle. The CI matrix runs the GUI smoke tests under
the Nix dev shell on Linux only; macOS GUI runs are documented as
deferred (the GitHub-hosted macOS runners require a separate Webkit
bring-up that is out of scope for the M15 release-readiness cut).

**What works:**

- The reader-bridge round-trips a recorder bundle into the GUI's
  trace tab.
- The VS Code DAP bridge accepts the bundle and surfaces the call
  stack.

**What's deferred:**

- macOS GUI smoke matrix.
- A "headless reader bench" against a 100k-event bundle (currently
  covered indirectly by the M17 stress fixtures, but not as a
  dedicated reader benchmark).

## M17: Phoenix/Plug fixture

The Phoenix/Plug smoke fixture ships as a hand-rolled `:gen_tcp`
HTTP/1.1 server shaped like `Plug.Router`. The recorder dev shell is
offline, so we cannot pull the `:plug` Hex package as a dependency.

**What works:**

- Real BEAM, real Mix, real socket traffic.
- `record` exits 0; the bundle round-trips through the reader.
- The handler call sequence (`Router.route -> dispatch -> render`)
  is asserted in `tests/integration/plug_smoke_test.exs`.

**What's deferred:**

- Pulling real `:plug` + `:cowboy` from Hex.pm and recording
  Phoenix's `mix phx.new --no-html --no-ecto`.

The fixture's API shape is a 1:1 match for `Plug.Router`, so swapping
the in-tree implementation for the Hex packages is mechanical.

## M17: macOS CI matrix

The Linux ecosystem matrix covers `(OTP 26 + Elixir 1.16)` and
`(OTP 27 + Elixir 1.17)`. macOS coverage is documented in
`CHANGELOG.md` as deferred follow-up. macOS support is not blocked by
any recorder-internal limitation; the deferral is purely a CI runner
provisioning concern.

## Source-file parser for module/function discovery

The recorder discovers `(module, function, arity)` triples by reading
`*.ex` and `*.erl` files line-by-line. This is intentionally simple
but has known limitations:

- Multiple `defmodule` blocks in one `.ex` file: only the first is
  recognized. Workaround: split into one module per file (Phoenix /
  Mix's standard layout already does this).
- Function-head argument lists with commas inside literals (maps,
  tuples, lists) inflate the detected arity. Workaround: refactor
  the head to bind the arg name and pattern-match in the body
  (`def f(req) do x = req.foo; ... end`).

The full `erl_anno`-based discovery from `+debug_info` is the
followup; the source-file parser is the M0-era bootstrap path.
