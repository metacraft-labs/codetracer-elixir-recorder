#!/usr/bin/env bash
set -euo pipefail

# M16 verification guard for the native-backend ordering stress test.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/native_tracer_ordering_test.exs"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/native_tracer_ordering_test.exs is missing"

grep -Fq 'e2e_native_tracer_ordering_stress' "$test_file" ||
  fail "$test_file must contain test \"e2e_native_tracer_ordering_stress\""

grep -Fq 'recorder_binary!' "$test_file" ||
  fail "native_tracer_ordering_test must launch the recorder binary"

grep -Fq '"native"' "$test_file" ||
  fail "native_tracer_ordering_test must use --tracer-backend native"

grep -Fq 'spawn_messages' "$test_file" ||
  fail "native_tracer_ordering_test must drive the spawn_messages flood fixture"

# The test must verify sequence numbers are strictly increasing AND
# contiguous (no silent drops).
grep -Fq 'sequence numbers must be strictly increasing' "$test_file" ||
  fail "native_tracer_ordering_test must assert sequence numbers are strictly increasing"

grep -Fq 'must be contiguous' "$test_file" ||
  fail "native_tracer_ordering_test must assert sequence numbers are contiguous (no drops)"

grep -Fq 'distinct thread_ids' "$test_file" ||
  fail "native_tracer_ordering_test must verify multiple thread_ids appear in the same stream"

printf 'OK: %s contains the required ordering oracle assertions\n' "$test_file"
