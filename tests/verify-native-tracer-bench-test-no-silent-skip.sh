#!/usr/bin/env bash
set -euo pipefail

# M16 verification guard for the native-tracer benchmark capture test.
# The test does not assert relative performance numbers (M16 is a
# baseline, not an optimization milestone), but it MUST run real
# fixtures under both backends and write the baseline to disk.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/native_tracer_bench_test.exs"
fixture_file="$repo_root/test-programs/erlang/native_tracer_bench/src/native_tracer_bench.erl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/native_tracer_bench_test.exs is missing"

[[ -f "$fixture_file" ]] ||
  fail "native_tracer_bench fixture missing at $fixture_file"

grep -Fq 'bench_native_tracer_overhead_real_fixtures' "$test_file" ||
  fail "$test_file must contain test \"bench_native_tracer_overhead_real_fixtures\""

grep -Fq 'recorder_binary!' "$test_file" ||
  fail "native_tracer_bench_test must launch the recorder binary"

# All three workloads must be exercised.
for entry in call_heavy process_heavy message_heavy; do
  grep -Fq "$entry" "$test_file" ||
    fail "native_tracer_bench_test must run the $entry fixture"

  grep -Fq "$entry" "$fixture_file" ||
    fail "fixture $fixture_file must export $entry/0"
done

# Both backends must be exercised.
grep -Fq '"process"' "$test_file" ||
  fail "native_tracer_bench_test must benchmark --tracer-backend process"

grep -Fq '"native"' "$test_file" ||
  fail "native_tracer_bench_test must benchmark --tracer-backend native"

grep -Fq 'native_tracer_baseline.md' "$test_file" ||
  fail "native_tracer_bench_test must write benches/native_tracer_baseline.md"

grep -Fq 'baseline must be written' "$test_file" ||
  fail "native_tracer_bench_test must assert the baseline file was written"

printf 'OK: %s captures a real-target benchmark baseline for both backends\n' "$test_file"
