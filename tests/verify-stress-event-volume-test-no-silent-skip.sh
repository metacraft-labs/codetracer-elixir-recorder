#!/usr/bin/env bash
set -euo pipefail

# M17 verification guard for tests/integration/stress_event_volume_test.exs.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/stress_event_volume_test.exs"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/stress_event_volume_test.exs is missing; M17 verification requires it"

# Five stress fixtures must exist on disk.
for fixture in stress_calls stress_processes stress_mailboxes stress_terms stress_crashes; do
  src="$repo_root/test-programs/erlang/$fixture/src/$fixture.erl"
  [[ -f "$src" ]] ||
    fail "stress fixture source missing: $src"

  grep -Fq "$fixture" "$test_file" ||
    fail "stress_event_volume_test must drive the $fixture fixture"
done

# 100k+ call assertion: stress_calls.erl must declare an N >= 100000.
n=$(grep -E '^-define\(N,\s*([0-9]+)\)\.' \
  "$repo_root/test-programs/erlang/stress_calls/src/stress_calls.erl" |
  sed -E 's/^-define\(N,\s*([0-9]+)\)\..*/\1/' | head -n1)

[[ -n "$n" ]] ||
  fail "stress_calls.erl must declare ?N via -define(N, INTEGER)"

if ((n < 100000)); then
  fail "stress_calls fixture must trace at least 100000 calls; declared N=$n"
fi

grep -Fq 'stress_beam_recorder_event_volume_real_targets' "$test_file" ||
  fail "$test_file must contain test \"stress_beam_recorder_event_volume_real_targets\""

# Real recorder + real BEAM + real reader.
grep -Fq 'recorder_binary!' "$test_file" ||
  fail "stress_event_volume_test must call recorder_binary!"

grep -Fq '"erl"' "$test_file" ||
  fail "stress_event_volume_test must launch real erl"

grep -Fq 'read-bundle-summary' "$test_file" ||
  fail "stress_event_volume_test must verify CTFS bundles via read-bundle-summary"

# RSS ceiling assertion is load-bearing — must remain in the file.
grep -Fq '@rss_ceiling_bytes' "$test_file" ||
  fail "stress_event_volume_test must declare @rss_ceiling_bytes ceiling"

grep -Fq 'peak_rss_bytes' "$test_file" ||
  fail "stress_event_volume_test must measure peak_rss_bytes"

# Refuse silent-skip patterns.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "stress_event_volume_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "stress_event_volume_test must not bail out via env var"
fi

if ! grep -F 'tests/integration/stress_event_volume_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/stress_event_volume_test.exs as part of \`just test-integration\`"
fi

printf 'PASS: verify_stress_event_volume_test_no_silent_skip\n'
