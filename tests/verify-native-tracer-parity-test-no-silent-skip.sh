#!/usr/bin/env bash
set -euo pipefail

# M16 verification guard: prevents tests/integration/native_tracer_parity_test.exs
# from silently turning into a no-op. Mirrors the pattern of the M5/M6
# verification guards.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/native_tracer_parity_test.exs"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/native_tracer_parity_test.exs is missing; M16 verification requires it"

grep -Fq 'e2e_native_tracer_event_parity' "$test_file" ||
  fail "$test_file must contain test \"e2e_native_tracer_event_parity\""

# Both backends must be exercised by the same test.
grep -Fq '"process"' "$test_file" ||
  fail "native_tracer_parity_test must record under --tracer-backend process"

grep -Fq '"native"' "$test_file" ||
  fail "native_tracer_parity_test must record under --tracer-backend native"

# The test must launch real BEAM processes; refuse stubbing.
grep -Fq 'recorder_binary!' "$test_file" ||
  fail "native_tracer_parity_test must call recorder_binary! — no mock recorder allowed"

grep -Fq '"erl"' "$test_file" ||
  fail "native_tracer_parity_test must launch erl for the Erlang fixture"

grep -Fq '"mix"' "$test_file" ||
  fail "native_tracer_parity_test must launch mix for the Elixir fixture"

# The test must read back the produced bundle through the same reader
# that runtime_session_test.exs uses.
grep -Fq 'read-bundle-summary' "$test_file" ||
  fail "native_tracer_parity_test must read back through read-bundle-summary"

# The parity assertion must compare module/MFA sets across backends.
grep -Fq 'process_modules == native_modules' "$test_file" ||
  fail "native_tracer_parity_test must assert equal module sets across backends"

grep -Fq 'process_mfas == native_mfas' "$test_file" ||
  fail "native_tracer_parity_test must assert equal MFA sets across backends"

printf 'OK: %s contains the required real-target M16 parity assertions\n' "$test_file"
