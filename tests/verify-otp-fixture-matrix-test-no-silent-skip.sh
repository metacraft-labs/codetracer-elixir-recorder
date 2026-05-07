#!/usr/bin/env bash
set -euo pipefail

# M17 verification guard: prevents
# tests/integration/otp_fixture_matrix_test.exs from silently turning
# into a no-op. Mirrors the M5/M6/M16 verification guards.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/otp_fixture_matrix_test.exs"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/otp_fixture_matrix_test.exs is missing; M17 verification requires it"

grep -Fq 'e2e_otp_fixture_matrix_real_trace' "$test_file" ||
  fail "$test_file must contain test \"e2e_otp_fixture_matrix_real_trace\""

# The OTP fixture matrix must cover six OTP behaviours.
for fixture in otp_genserver otp_supervisor otp_task otp_agent otp_ets otp_application; do
  grep -Fq "$fixture" "$test_file" ||
    fail "$test_file must drive the $fixture fixture"

  [[ -d "$repo_root/test-programs/elixir/$fixture" ]] ||
    fail "test-programs/elixir/$fixture fixture directory missing"

  [[ -f "$repo_root/test-programs/elixir/$fixture/mix.exs" ]] ||
    fail "$fixture must have a mix.exs"
done

# Real recorder + real bundle reader.
grep -Fq 'recorder_binary!' "$test_file" ||
  fail "otp_fixture_matrix_test must call recorder_binary! — no mock recorder allowed"

grep -Fq 'read-bundle-summary' "$test_file" ||
  fail "otp_fixture_matrix_test must verify CTFS bundles via read-bundle-summary"

grep -Fq '"mix"' "$test_file" ||
  fail "otp_fixture_matrix_test must launch real mix to drive the OTP fixtures"

# Refuse silent-skip patterns.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "otp_fixture_matrix_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "otp_fixture_matrix_test must not bail out via env var"
fi

# Justfile must wire it into `just test-integration` so CI cannot miss it.
if ! grep -F 'tests/integration/otp_fixture_matrix_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/otp_fixture_matrix_test.exs as part of \`just test-integration\`"
fi

printf 'PASS: verify_otp_fixture_matrix_test_no_silent_skip\n'
