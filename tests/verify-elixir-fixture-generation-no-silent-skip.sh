#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/prepare-elixir-fixture.sh"

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
work_dir="$(mktemp -d "$tmp_root/elixir-fixture-no-skip.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

expect_failure "missing-recorder" \
  env CI=1 CODETRACER_ELIXIR_RECORDER_BIN="$work_dir/missing-recorder" \
    "$script" "$work_dir/missing-recorder-out"

expect_failure "missing-recorder-repo" \
  env CI=1 CODETRACER_ELIXIR_RECORDER_PATH="$work_dir/missing-repo" \
    "$script" "$work_dir/missing-repo-out"

expect_failure "missing-canonical-fixture" \
  env CI=1 CODETRACER_ELIXIR_FLOW_TEST="$work_dir/missing-canonical-flow" \
    "$script" "$work_dir/missing-fixture-out"

printf 'PASS: verify_elixir_fixture_generation_no_silent_skip\n'
