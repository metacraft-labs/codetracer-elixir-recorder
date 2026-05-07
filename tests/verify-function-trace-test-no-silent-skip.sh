#!/usr/bin/env bash
set -euo pipefail

# Guards that tests/integration/function_trace_test.exs cannot quietly turn
# itself into a no-op: every M5 verification entry must require the recorder
# binary, the BEAM toolchain, the canonical fixtures, and the new exception
# fixture. Mirrors verify-runtime-session-test-no-silent-skip.sh in spirit.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/function_trace_test.exs"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/function_trace_test.exs is missing; M5 verification requires it"

for name in \
  e2e_runtime_records_canonical_call_return_sequence \
  e2e_runtime_records_real_exception_fixture \
  e2e_runtime_call_trace_reader_roundtrip; do
  grep -Fq "\"$name\"" "$test_file" ||
    fail "$test_file must contain test \"$name\""
done

# All three M5 tests must launch the real recorder binary; refuse silent
# skips that swap in a mock recorder.
grep -Fq 'recorder_binary!' "$test_file" ||
  fail "function_trace_test must call recorder_binary! — no mock recorder allowed"

# Canonical Elixir/Erlang fixtures + the new exception fixture must all
# appear so each test path exercises the BEAM VM end-to-end.
grep -Fq 'test-programs/elixir/canonical_flow' "$test_file" ||
  fail "function_trace_test must drive the canonical Elixir fixture"
grep -Fq 'test-programs/erlang/canonical_flow' "$test_file" ||
  fail "function_trace_test must drive the canonical Erlang fixture"
grep -Fq 'test-programs/elixir/exception_flow' "$test_file" ||
  fail "function_trace_test must drive the exception_flow crash fixture"

# The exception fixture's `crash` entrypoint must be invoked through `mix run`
# so the test exercises an uncaught exception path — without it the runtime
# never produces the M5 exception_from records.
grep -Fq 'ExceptionFlow.crash' "$test_file" ||
  fail "function_trace_test must invoke ExceptionFlow.crash() to exercise uncaught exception unwinding"

# CTFS bundle queries must go through the recorder binary's
# read-bundle-summary subcommand (which wraps NimTraceReaderHandle).
grep -Fq 'read-bundle-summary' "$test_file" ||
  fail "function_trace_test must verify CTFS bundles via the read-bundle-summary recorder subcommand"

# Reader assertions specific to M5 — function table, call records, and the
# exception_from special event must all be covered.
for token in \
  'function_count' \
  'function_names' \
  'call_count' \
  'call_function_ids' \
  'call_json' \
  'exception_from_count' \
  'exception_from_records' \
  'target_exit_code'; do
  grep -Fq "$token" "$test_file" ||
    fail "function_trace_test must assert on $token"
done

# Refuse common silent-skip patterns: ExUnit @tag :skip, or env-var bail-outs.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "function_trace_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "function_trace_test must not bail out via env var"
fi

# Confirm the Justfile wires the test into `just test` so CI cannot miss it.
if ! grep -F 'tests/integration/function_trace_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/function_trace_test.exs as part of \`just test-integration\`"
fi

# The exception fixture file must actually contain the deterministic
# `crash/0` entry point — otherwise the test would silently exercise a
# rescued path and miss the exception_from contract.
fixture="$repo_root/test-programs/elixir/exception_flow/lib/exception_flow.ex"
[[ -f "$fixture" ]] || fail "exception_flow fixture is missing at $fixture"
grep -Eq '^[[:space:]]*def[[:space:]]+crash[[:space:]]*do' "$fixture" ||
  fail "$fixture must define crash/0 as the M5 deterministic-uncaught-exception entrypoint"
grep -Eq '^[[:space:]]*def[[:space:]]+crash_inner[[:space:]]*do' "$fixture" ||
  fail "$fixture must define crash_inner/0 so two MFAs unwind through exception_from"

printf 'PASS: verify_function_trace_test_no_silent_skip\n'
