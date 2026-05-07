#!/usr/bin/env bash
# =============================================================================
# Record CodeTracer BEAM canonical UI/WDIO fixtures (Elixir + Erlang).
#
# This is the M15 fixture-generation entry point. It records both the
# Elixir and Erlang canonical_flow programs with the real
# codetracer-beam-recorder so that:
#
#   - codetracer Playwright UI smoke tests
#       (codetracer/tsc-ui-tests/tests/elixir-canonical-flow.spec.ts and
#        codetracer/tsc-ui-tests/tests/erlang-canonical-flow.spec.ts)
#   - codetracer-vscode-extension WDIO smoke tests
#       (test/wdio/specs/smoke/elixir.e2e.ts,
#        test/wdio/specs/smoke/erlang.e2e.ts)
#   - codetracer-vscode-extension WDIO deep test
#       (test/wdio/specs/deep/beam-deep.e2e.ts)
#
# can all consume real CTFS bundles instead of pre-baked goldens.
#
# Per the M15 plan (decision 1): UI tests regenerate from source in CI rather
# than store full trace artifacts, because regeneration is fast (seconds) and
# stale bundles would mask recorder regressions.
#
# Per the M15 plan (decision 2): The deep WDIO test reuses one BEAM fixture
# (canonical_flow) shared across Elixir and Erlang variants; the goal is GUI
# navigation depth verification, not duplicating per-language assertions.
#
# Usage:
#   scripts/prepare-beam-fixtures.sh [ELIXIR_OUT_DIR] [ERLANG_OUT_DIR]
#
# Arguments and overrides (positional > env > defaults):
#   ELIXIR_OUT_DIR
#     Where to write the Elixir CTFS bundle. Defaults to
#     $ELIXIR_FIXTURE_OUTPUT_DIR or
#     <repo>/target/fixtures/elixir-canonical-flow.
#   ERLANG_OUT_DIR
#     Where to write the Erlang CTFS bundle. Defaults to
#     $ERLANG_FIXTURE_OUTPUT_DIR or
#     <repo>/target/fixtures/erlang-canonical-flow.
#
# Environment overrides (consumed in addition to those of
# prepare-elixir-fixture.sh):
#   CODETRACER_BEAM_RECORDER_PATH    Recorder repo override.
#   CODETRACER_BEAM_RECORDER_BIN     Recorder binary override.
#   CODETRACER_ELIXIR_FLOW_TEST      Canonical Elixir Mix project override.
#   CODETRACER_ERLANG_FLOW_TEST      Canonical Erlang OTP project override.
#   FORCE=1                          Regenerate even when fixtures exist.
#   CI=1                             Always regenerate; no reuse.
#   PREPARE_BEAM_FIXTURES_SKIP_ELIXIR=1
#                                    Skip Elixir recording (debugging only).
#   PREPARE_BEAM_FIXTURES_SKIP_ERLANG=1
#                                    Skip Erlang recording (debugging only).
#
# Failure semantics (no silent skips — verified by
# scripts/../tests/verify-beam-fixture-generation-no-silent-skip.sh):
#   - Missing recorder binary, recorder repo, or canonical fixture project
#     causes a hard FAIL with diagnostic output on stderr.
#   - A recording that produces an invalid bundle (zero events, missing
#     trace.ct, missing trace_metadata.json) causes a hard FAIL.
#   - Missing elixir/mix/erl/erlc with no recoverable nix devShell causes a
#     hard FAIL rather than producing an empty fixture.
#
# Output (machine-readable):
#   On success, the last two lines printed to stdout are JSON objects
#   describing each prepared bundle, e.g.:
#     {"language":"elixir","trace_dir":"/.../elixir-canonical-flow"}
#     {"language":"erlang","trace_dir":"/.../erlang-canonical-flow"}
# =============================================================================

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/prepare-beam-fixtures.sh [ELIXIR_OUT_DIR] [ERLANG_OUT_DIR]

Records the canonical Elixir and Erlang BEAM fixtures with the real
codetracer-beam-recorder. See header in this script for the full list of
environment overrides and failure semantics.
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_repo_root="$(cd "$script_dir/.." && pwd)"

# ----------------------------------------------------------------------------
# Recorder repo + binary resolution. Mirrors prepare-elixir-fixture.sh so we
# fail loudly with the same diagnostic strings.
# ----------------------------------------------------------------------------
if [[ -n "${CODETRACER_BEAM_RECORDER_PATH:-}" ]]; then
  recorder_repo="$CODETRACER_BEAM_RECORDER_PATH"
  [[ -d "$recorder_repo" ]] ||
    fail "CODETRACER_BEAM_RECORDER_PATH does not exist: $recorder_repo"
elif [[ -n "${CODETRACER_ELIXIR_RECORDER_PATH:-}" ]]; then
  recorder_repo="$CODETRACER_ELIXIR_RECORDER_PATH"
  [[ -d "$recorder_repo" ]] ||
    fail "CODETRACER_ELIXIR_RECORDER_PATH does not exist: $recorder_repo"
  printf '[codetracer-beam-recorder] note: CODETRACER_ELIXIR_RECORDER_PATH is deprecated; please use CODETRACER_BEAM_RECORDER_PATH.\n' >&2
else
  recorder_repo="$script_repo_root"
fi
recorder_repo="$(cd "$recorder_repo" && pwd)"

elixir_default_out="$script_repo_root/target/fixtures/elixir-canonical-flow"
erlang_default_out="$script_repo_root/target/fixtures/erlang-canonical-flow"

elixir_out_dir="${1:-${ELIXIR_FIXTURE_OUTPUT_DIR:-$elixir_default_out}}"
erlang_out_dir="${2:-${ERLANG_FIXTURE_OUTPUT_DIR:-$erlang_default_out}}"

mkdir -p "$(dirname "$elixir_out_dir")"
mkdir -p "$(dirname "$erlang_out_dir")"

# ----------------------------------------------------------------------------
# Canonical fixture project resolution.
# ----------------------------------------------------------------------------
elixir_project="${CODETRACER_ELIXIR_FLOW_TEST:-$recorder_repo/test-programs/elixir/canonical_flow}"
erlang_project="${CODETRACER_ERLANG_FLOW_TEST:-$recorder_repo/test-programs/erlang/canonical_flow}"

[[ -f "$elixir_project/mix.exs" ]] ||
  fail "canonical Elixir Mix fixture not found: $elixir_project (expected mix.exs)"
[[ -f "$erlang_project/src/canonical_flow.erl" ]] ||
  fail "canonical Erlang fixture not found: $erlang_project (expected src/canonical_flow.erl)"

# ----------------------------------------------------------------------------
# Recorder binary resolution.
# ----------------------------------------------------------------------------
find_recorder_bin() {
  if [[ -n "${CODETRACER_BEAM_RECORDER_BIN:-}" ]]; then
    [[ -x "$CODETRACER_BEAM_RECORDER_BIN" ]] ||
      fail "CODETRACER_BEAM_RECORDER_BIN is not executable: $CODETRACER_BEAM_RECORDER_BIN"
    printf '%s\n' "$CODETRACER_BEAM_RECORDER_BIN"
    return
  fi

  if [[ -n "${CODETRACER_ELIXIR_RECORDER_BIN:-}" ]]; then
    [[ -x "$CODETRACER_ELIXIR_RECORDER_BIN" ]] ||
      fail "CODETRACER_ELIXIR_RECORDER_BIN is not executable: $CODETRACER_ELIXIR_RECORDER_BIN"
    printf '[codetracer-beam-recorder] note: CODETRACER_ELIXIR_RECORDER_BIN is deprecated; please use CODETRACER_BEAM_RECORDER_BIN.\n' >&2
    printf '%s\n' "$CODETRACER_ELIXIR_RECORDER_BIN"
    return
  fi

  if command -v codetracer-beam-recorder >/dev/null 2>&1; then
    command -v codetracer-beam-recorder
    return
  fi

  for candidate in \
    "$recorder_repo/target/debug/codetracer-beam-recorder" \
    "$recorder_repo/target/release/codetracer-beam-recorder" \
    "$recorder_repo/target/debug/codetracer-elixir-recorder" \
    "$recorder_repo/target/release/codetracer-elixir-recorder"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  # Last resort: build the recorder. This is what makes the script
  # self-bootstrapping in CI without ever silently skipping.
  if command -v cargo >/dev/null 2>&1; then
    printf '[codetracer-beam-recorder] recorder binary not found; running cargo build --locked\n' >&2
    (cd "$recorder_repo" && cargo build --locked >&2)
    for candidate in \
      "$recorder_repo/target/debug/codetracer-beam-recorder" \
      "$recorder_repo/target/release/codetracer-beam-recorder"; do
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
      fi
    done
  fi

  fail "codetracer-beam-recorder binary not found; build the recorder or set CODETRACER_BEAM_RECORDER_BIN"
}

recorder_bin="$(find_recorder_bin)"
recorder_bin_dir="$(cd "$(dirname "$recorder_bin")" && pwd)"

# ----------------------------------------------------------------------------
# BEAM toolchain detection. If elixir/mix/erl/erlc are missing, attempt to
# re-exec inside the recorder's nix devShell or direnv environment. If neither
# is available, fail loudly so CI sees the diagnostic instead of producing an
# empty fixture and skipping silently.
# ----------------------------------------------------------------------------
beam_tools_present() {
  command -v elixirc >/dev/null 2>&1 &&
    command -v mix >/dev/null 2>&1 &&
    command -v erl >/dev/null 2>&1 &&
    command -v erlc >/dev/null 2>&1
}

if ! beam_tools_present && [[ "${CODETRACER_BEAM_FIXTURES_IN_RECORDER_ENV:-0}" != "1" ]]; then
  if [[ -f "$recorder_repo/.envrc" ]] && command -v direnv >/dev/null 2>&1; then
    exec env CODETRACER_BEAM_FIXTURES_IN_RECORDER_ENV=1 \
      direnv exec "$recorder_repo" bash "$script_dir/prepare-beam-fixtures.sh" \
      "$elixir_out_dir" "$erlang_out_dir"
  fi
  if command -v nix >/dev/null 2>&1 && [[ -f "$recorder_repo/flake.nix" ]]; then
    exec env CODETRACER_BEAM_FIXTURES_IN_RECORDER_ENV=1 \
      nix develop "$recorder_repo" -c bash "$script_dir/prepare-beam-fixtures.sh" \
      "$elixir_out_dir" "$erlang_out_dir"
  fi
fi

if ! beam_tools_present; then
  command -v elixirc >/dev/null 2>&1 || fail "elixirc is required to prepare BEAM fixtures (no nix/direnv recovery available)"
  command -v mix >/dev/null 2>&1 || fail "mix is required to prepare BEAM fixtures (no nix/direnv recovery available)"
  command -v erl >/dev/null 2>&1 || fail "erl is required to prepare BEAM fixtures (no nix/direnv recovery available)"
  command -v erlc >/dev/null 2>&1 || fail "erlc is required to prepare BEAM fixtures (no nix/direnv recovery available)"
fi

# ----------------------------------------------------------------------------
# Validation helper. After a recording, both languages produce a CTFS bundle
# directory; we verify it has at least one .ct file plus the expected metadata.
# A bundle with zero events would still write a tiny .ct, so we additionally
# check that the .ct file is non-empty and that the trace_paths.json points to
# the canonical source.
# ----------------------------------------------------------------------------
validate_bundle() {
  local language="$1"
  local out_dir="$2"
  local source_relpath="$3"

  [[ -d "$out_dir" ]] ||
    fail "$language fixture directory missing after recording: $out_dir"
  [[ -f "$out_dir/trace_metadata.json" ]] ||
    fail "$language fixture missing trace_metadata.json: $out_dir"
  [[ -f "$out_dir/trace_paths.json" ]] ||
    fail "$language fixture missing trace_paths.json: $out_dir"

  # CTFS bundle: at least one non-empty .ct file at the bundle root.
  local found_ct=""
  while IFS= read -r ct; do
    if [[ -s "$ct" ]]; then
      found_ct="$ct"
      break
    fi
  done < <(find "$out_dir" -maxdepth 1 -name '*.ct' -type f -print)
  [[ -n "$found_ct" ]] ||
    fail "$language fixture has no non-empty .ct file in $out_dir (recorder produced an empty trace)"

  # Source files mirrored under <out>/files so the GUI can resolve absolute
  # paths from trace_paths.json regardless of where the recorder ran.
  [[ -f "$out_dir/files/$source_relpath" ]] ||
    fail "$language fixture did not mirror source file at $out_dir/files/$source_relpath"
}

# ----------------------------------------------------------------------------
# Elixir branch. Re-uses prepare-elixir-fixture.sh (already proven by M14 DAP
# tests) so we don't duplicate the Mix task compilation logic.
# ----------------------------------------------------------------------------
record_elixir() {
  if [[ "${PREPARE_BEAM_FIXTURES_SKIP_ELIXIR:-0}" == "1" ]]; then
    printf '[codetracer-beam-recorder] PREPARE_BEAM_FIXTURES_SKIP_ELIXIR=1 — skipping Elixir (debug only)\n' >&2
    return
  fi

  printf '[codetracer-beam-recorder] recording Elixir canonical_flow into %s\n' "$elixir_out_dir"
  CODETRACER_BEAM_RECORDER_PATH="$recorder_repo" \
    CODETRACER_BEAM_RECORDER_BIN="$recorder_bin" \
    CODETRACER_ELIXIR_FLOW_TEST="$elixir_project" \
    CODETRACER_BEAM_FIXTURES_IN_RECORDER_ENV=1 \
    bash "$script_dir/prepare-elixir-fixture.sh" "$elixir_out_dir"

  validate_bundle "elixir" "$elixir_out_dir" "lib/canonical_flow.ex"
}

# ----------------------------------------------------------------------------
# Erlang branch. Compiles canonical_flow.erl with debug_info, then drives the
# recorder around `erl -noshell -pa <ebin> -s canonical_flow main -s init
# stop`. Mirrors src/db-backend/tests/test_harness/mod.rs::record_erlang_trace
# so the UI fixture and DAP fixture stay byte-equivalent.
# ----------------------------------------------------------------------------
record_erlang() {
  if [[ "${PREPARE_BEAM_FIXTURES_SKIP_ERLANG:-0}" == "1" ]]; then
    printf '[codetracer-beam-recorder] PREPARE_BEAM_FIXTURES_SKIP_ERLANG=1 — skipping Erlang (debug only)\n' >&2
    return
  fi

  if [[ -d "$erlang_out_dir" && "${FORCE:-0}" != "1" && -z "${CI:-}" ]]; then
    if [[ -f "$erlang_out_dir/trace_metadata.json" ]] &&
      [[ -f "$erlang_out_dir/trace_paths.json" ]] &&
      find "$erlang_out_dir" -maxdepth 1 -name '*.ct' -type f | grep -q .; then
      printf '[codetracer-beam-recorder] Erlang fixture already exists at %s; set FORCE=1 to regenerate.\n' "$erlang_out_dir"
      return
    fi
  fi

  rm -rf "$erlang_out_dir"
  mkdir -p "$erlang_out_dir"

  local tmp_root="${TMPDIR:-$(dirname "$erlang_out_dir")/.tmp}"
  mkdir -p "$tmp_root"
  local work_dir
  work_dir="$(mktemp -d "$tmp_root/codetracer-erlang-fixture.XXXXXX")"
  # shellcheck disable=SC2064  # intentional expansion of $work_dir at trap install time
  trap "rm -rf '$work_dir'" RETURN

  local ebin_dir="$work_dir/ebin"
  mkdir -p "$ebin_dir"

  printf '[codetracer-beam-recorder] compiling Erlang canonical_flow.erl with +debug_info\n'
  erlc +debug_info -o "$ebin_dir" "$erlang_project/src/canonical_flow.erl"

  printf '[codetracer-beam-recorder] recording Erlang canonical_flow into %s\n' "$erlang_out_dir"
  (
    cd "$erlang_project"
    env \
      TMPDIR="$tmp_root" \
      CODETRACER_BEAM_RECORDER_ROOT="$recorder_repo" \
      CODETRACER_BEAM_RECORDER_BIN="$recorder_bin" \
      PATH="$recorder_bin_dir:$PATH" \
      "$recorder_bin" record \
      --out-dir "$erlang_out_dir" \
      -- erl -noshell -pa "$ebin_dir" -s canonical_flow main -s init stop
  )

  # Mirror the canonical Erlang source under <out>/files like the Elixir
  # branch does, so the UI's path resolver can find canonical_flow.erl from
  # the absolute paths in trace_paths.json.
  local absolute_project_copy="$erlang_out_dir/files/${erlang_project#/}"
  mkdir -p "$(dirname "$absolute_project_copy")"
  rm -rf "$absolute_project_copy"
  cp -R "$erlang_project" "$absolute_project_copy"

  # Some recorder paths emit only a CTFS .ct without trace_paths.json (the
  # writer's responsibility evolves milestone-to-milestone). Backfill them
  # with the canonical source so the UI fixture is self-contained.
  if [[ ! -f "$erlang_out_dir/trace_metadata.json" ]]; then
    local escaped_project
    escaped_project="$(json_escape "$erlang_project")"
    cat >"$erlang_out_dir/trace_metadata.json" <<EOF
{
  "program": "$escaped_project",
  "args": ["canonical_flow:main"],
  "workdir": "$escaped_project"
}
EOF
  fi
  if [[ ! -f "$erlang_out_dir/trace_paths.json" ]]; then
    local escaped_source
    escaped_source="$(json_escape "$erlang_project/src/canonical_flow.erl")"
    cat >"$erlang_out_dir/trace_paths.json" <<EOF
["$escaped_source"]
EOF
  fi

  validate_bundle "erlang" "$erlang_out_dir" "src/canonical_flow.erl"
}

record_elixir
record_erlang

# Machine-parseable trailer for callers (Playwright/WDIO specs) that want to
# capture the fixture paths from stdout without scraping log lines.
if [[ "${PREPARE_BEAM_FIXTURES_SKIP_ELIXIR:-0}" != "1" ]]; then
  printf '{"language":"elixir","trace_dir":"%s"}\n' "$(json_escape "$elixir_out_dir")"
fi
if [[ "${PREPARE_BEAM_FIXTURES_SKIP_ERLANG:-0}" != "1" ]]; then
  printf '{"language":"erlang","trace_dir":"%s"}\n' "$(json_escape "$erlang_out_dir")"
fi

printf '[codetracer-beam-recorder] BEAM canonical fixtures ready.\n' >&2
