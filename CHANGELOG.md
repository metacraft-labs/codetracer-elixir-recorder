# Changelog

All notable changes to the CodeTracer BEAM materialized trace recorder
are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are SemVer; the canonical version lives in `Cargo.toml`.

## [Unreleased]

## [0.1.0] - 2026-05-08

This is the M17 release-hardening cut. The recorder is feature-complete
for the BEAM v1 surface area defined in milestones M0-M16. M17 adds the
release-readiness layer: CI matrix, OTP fixture coverage, stress
fixtures, packaging metadata, user documentation, and a release-check
gate.

### Added

- M0-M2: public scaffold, golden fixture contract, latest CTFS writer
  bridge, repository compliance harness.
- M3: standalone `record` CLI that drives a real BEAM target and
  produces a CTFS bundle.
- M4: minimal BEAM runtime session with `erlang:trace_delivered/1`
  shutdown barrier.
- M5: runtime function call/return/exception tracing through
  `erlang:trace/3`.
- M6: BEAM process and message tracing (`procs`, `set_on_spawn`,
  `send`, `receive`).
- M7: per-module recorder manifests under
  `recorder_metadata/manifests/`.
- M8: abstract-form-driven step instrumentation (process backend).
- M9: clause-entry variable bindings.
- M10: BEAM term value encoder.
- M11: standalone instrumented build CLI.
- M12: Mix integration via `mix codetracer.record` + Elixir source
  maps.
- M13: Rebar3 integration via the `rebar3_codetracer` plugin app.
- M14: cross-repo DAP flow integration.
- M15: UI + VS Code smoke parity (sibling-pinned to
  `codetracer-vscode-extension`).
- M16: optimized `erl_tracer`-style native backend (gen_server seam;
  see `:scope_deferred:` in the milestones plan for the deferred
  real-NIF follow-up).
- M17: CI matrix (Ubuntu Linux, OTP 26 + 27, Elixir 1.16 + 1.17), OTP
  fixture matrix (GenServer, Supervisor, Task, Agent, ETS, Application
  startup/shutdown), Phoenix/Plug-shaped smoke fixture, five stress
  fixtures (100k+ calls, many short-lived processes, large mailboxes,
  large terms, abrupt crashes), Hex/Mix/Rebar3/Cargo packaging
  metadata, user docs, and `just release-check`.

### Notes

- Phoenix/Plug fixture: the M17 recorder dev shell is offline so the
  smoke fixture uses a hand-rolled `:gen_tcp` HTTP/1.1 server shaped
  like `Plug.Router` instead of pulling the `:plug` Hex package. The
  recorder contract under test (`record` exits 0, the bundle is
  reader-loadable, the request handler call sequence is present) is
  the same contract a Phoenix `--no-html --no-ecto` app would
  exercise. Swapping the fixture for real Plug + Cowboy is mechanical.
- macOS CI matrix is documented but not currently run; the
  `nix-build` job is Linux-only because the Nix dev shell is a
  primary GitHub-hosted Linux runner. macOS coverage is open
  follow-up.
