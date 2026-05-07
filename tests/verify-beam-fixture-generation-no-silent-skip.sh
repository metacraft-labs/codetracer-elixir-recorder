#!/usr/bin/env bash
# =============================================================================
# Verify that scripts/prepare-beam-fixtures.sh fails loudly when the BEAM
# fixture-generation prerequisites are missing.
#
# Companion to verify-elixir-fixture-generation-no-silent-skip.sh; covers the
# combined Elixir + Erlang entry point introduced in M15. The script
# intentionally does NOT verify a successful recording — that is the
# responsibility of the M15 Playwright + WDIO suites which exercise the script
# end-to-end inside the recorder's nix devShell.
#
# Failure modes covered:
#   - missing-recorder-bin   : CODETRACER_BEAM_RECORDER_BIN points to a
#                              non-existent path.
#   - missing-recorder-repo  : CODETRACER_BEAM_RECORDER_PATH points to a
#                              non-existent directory.
#   - missing-elixir-fixture : CODETRACER_ELIXIR_FLOW_TEST points to a
#                              missing Mix project.
#   - missing-erlang-fixture : CODETRACER_ERLANG_FLOW_TEST points to a
#                              missing OTP project (canonical_flow.erl
#                              absent).
#
# Each failure must (a) exit non-zero and (b) print a "FAIL:" diagnostic on
# stderr — that is the contract relied on by CI to distinguish a real failure
# from an accidental "silent skip" pass.
# =============================================================================

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/prepare-beam-fixtures.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local name="$1"
  shift
  local log="$work_dir/$name.log"

  set +e
  "$@" >"$log" 2>&1
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    cat "$log" >&2
    fail "$name unexpectedly succeeded"
  fi
  if ! grep -q 'FAIL:' "$log"; then
    cat "$log" >&2
    fail "$name failed without a loud FAIL diagnostic"
  fi
}

[[ -x "$script" ]] || fail "fixture preparation script is not executable: $script"

tmp_root="${TMPDIR:-$repo_root/target/.tmp}"
mkdir -p "$tmp_root"
work_dir="$(mktemp -d "$tmp_root/beam-fixture-no-skip.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

expect_failure "missing-recorder-bin" \
  env CI=1 CODETRACER_BEAM_RECORDER_BIN="$work_dir/missing-recorder-bin" \
    "$script" "$work_dir/missing-bin-elixir-out" "$work_dir/missing-bin-erlang-out"

expect_failure "missing-recorder-repo" \
  env CI=1 CODETRACER_BEAM_RECORDER_PATH="$work_dir/missing-repo" \
    "$script" "$work_dir/missing-repo-elixir-out" "$work_dir/missing-repo-erlang-out"

expect_failure "missing-elixir-fixture" \
  env CI=1 CODETRACER_ELIXIR_FLOW_TEST="$work_dir/missing-elixir-canonical-flow" \
    "$script" "$work_dir/missing-elixir-fixture-out" "$work_dir/erlang-out"

expect_failure "missing-erlang-fixture" \
  env CI=1 CODETRACER_ERLANG_FLOW_TEST="$work_dir/missing-erlang-canonical-flow" \
    "$script" "$work_dir/elixir-out" "$work_dir/missing-erlang-fixture-out"

printf 'PASS: verify_beam_fixture_generation_no_silent_skip\n'
