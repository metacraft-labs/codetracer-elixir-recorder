#!/usr/bin/env bash
set -euo pipefail

# M16 verification guard for the native-backend overflow diagnostic test.
# Silent event loss is a release blocker, so this guard is paranoid.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/native_tracer_overflow_test.exs"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/native_tracer_overflow_test.exs is missing"

grep -Fq 'e2e_native_tracer_overflow_diagnostic' "$test_file" ||
  fail "$test_file must contain test \"e2e_native_tracer_overflow_diagnostic\""

grep -Fq 'recorder_binary!' "$test_file" ||
  fail "native_tracer_overflow_test must launch the recorder binary"

grep -Fq -- '--tracer-queue-limit' "$test_file" ||
  fail "native_tracer_overflow_test must drive --tracer-queue-limit to force overflow"

grep -Fq -- '--tracer-overflow-policy' "$test_file" ||
  fail "native_tracer_overflow_test must exercise --tracer-overflow-policy"

grep -Fq '"drop"' "$test_file" ||
  fail "native_tracer_overflow_test must exercise the drop policy"

grep -Fq '"block"' "$test_file" ||
  fail "native_tracer_overflow_test must contrast the drop policy against the block policy"

grep -Fq 'recorder_overflow' "$test_file" ||
  fail "native_tracer_overflow_test must assert the recorder_overflow diagnostic line is emitted"

grep -Fq 'Silent event loss' "$test_file" ||
  fail "native_tracer_overflow_test must explicitly call out silent event loss as a blocker"

grep -Fq 'block policy must guarantee zero dropped events' "$test_file" ||
  fail "native_tracer_overflow_test must assert block policy never drops events"

printf 'OK: %s contains the required overflow diagnostic assertions\n' "$test_file"
