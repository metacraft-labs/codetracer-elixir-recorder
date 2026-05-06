# codetracer-elixir-recorder

This repository contains the public scaffold for the CodeTracer Elixir and
Erlang materialized trace recorder. M0 intentionally provides packaging,
compliance checks, and a minimal CLI only; recorder behavior starts in later
milestones.

## Commands

- `just build` builds the recorder package.
- `just test` runs Rust tests plus real Elixir, Erlang, and CLI smoke tests.
- `just lint` runs Nix, Rust, shell, and repository compliance checks.
- `just format` or `just fmt` formats Nix, Rust, and shell files.
- `just bump-version <MAJOR.MINOR.PATCH>` updates the Cargo package version and
  dependent lockfile metadata.

## Project Structure

- `flake.nix` defines the shared Nix dev shell, package exports, and git hooks.
- `Cargo.toml`, `Cargo.lock`, and `src/` hold the minimal recorder CLI package.
- `.github/workflows/ci.yml` mirrors the Just targets used locally.
- `.github/sibling-pins.json` pins public CodeTracer sibling repos for future
  cross-repo CI.
- `tests/verify-repo-requirements.sh` is the executable compliance harness.

## Conventions

- Keep the binary name `codetracer-elixir-recorder`.
- Keep `Cargo.toml` as the version source of truth and update it through
  `just bump-version`.
- Do not add recorder behavior without real integration tests that exercise the
  BEAM VM and trace writer.
- Prefer small, explicit shell checks in the compliance harness over placeholder
  checks.
