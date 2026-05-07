#!/usr/bin/env bash
set -euo pipefail

# Guards that tests/integration/runtime_session_test.exs cannot quietly turn
# itself into a no-op: every assertion path must require the recorder binary,
# the BEAM toolchain, and the canonical fixtures. Mirrors
# verify-elixir-fixture-generation-no-silent-skip.sh in spirit.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/runtime_session_test.exs"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[[ -f "$test_file" ]] ||
	fail "tests/integration/runtime_session_test.exs is missing; M4 verification requires it"

grep -Fq 'e2e_runtime_session_records_real_elixir_process' "$test_file" ||
	fail "$test_file must contain test \"e2e_runtime_session_records_real_elixir_process\""

grep -Fq 'e2e_runtime_session_records_real_erlang_process' "$test_file" ||
	fail "$test_file must contain test \"e2e_runtime_session_records_real_erlang_process\""

# The test must actually launch the recorder binary against `mix` and `erl`;
# refuse skipping via env var.
grep -Fq 'recorder_binary!' "$test_file" ||
	fail "runtime_session_test must call recorder_binary! — no mock recorder allowed"

grep -Fq '"mix"' "$test_file" ||
	fail "runtime_session_test must launch mix for the Elixir fixture"

grep -Fq '"erl"' "$test_file" ||
	fail "runtime_session_test must launch erl for the Erlang fixture"

# The test must read back the produced bundle through the same reader that
# ctfs_writer_bridge_test.exs uses — i.e. the recorder binary's
# read-bundle-summary subcommand which wraps NimTraceReaderHandle.
grep -Fq 'read-bundle-summary' "$test_file" ||
	fail "runtime_session_test must verify CTFS bundles via the read-bundle-summary recorder subcommand"

grep -Fq 'thread_start_count_root' "$test_file" ||
	fail "runtime_session_test must assert on root ThreadStart count"

grep -Fq 'thread_switch_count_root' "$test_file" ||
	fail "runtime_session_test must assert on root ThreadSwitch count"

grep -Fq 'thread_exit_count_root' "$test_file" ||
	fail "runtime_session_test must assert on root ThreadExit count"

grep -Fq '"language"' "$test_file" ||
	fail "runtime_session_test must assert on trace_meta.json language metadata"

grep -Fq 'sidecar_trace_delivered' "$test_file" ||
	fail "runtime_session_test must assert that the runtime session finalized through trace_delivered"

# Refuse common silent-skip patterns: ExUnit @tag :skip, or env-var bail-outs.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
	fail "runtime_session_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
	fail "runtime_session_test must not bail out via env var"
fi

# Confirm the Justfile wires the test into `just test` so CI cannot miss it.
if ! grep -F 'tests/integration/runtime_session_test.exs' "$repo_root/Justfile" >/dev/null; then
	fail "Justfile must run tests/integration/runtime_session_test.exs as part of \`just test-integration\`"
fi

printf 'PASS: verify_runtime_session_test_no_silent_skip\n'
