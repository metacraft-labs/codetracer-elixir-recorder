#!/usr/bin/env bash
set -euo pipefail

# Guards that tests/integration/message_trace_test.exs cannot quietly turn
# itself into a no-op: every M6 verification entry must require the recorder
# binary, the BEAM toolchain, the task_messages and spawn_messages fixtures,
# and the read-bundle-summary reader bridge. Mirrors
# verify-function-trace-test-no-silent-skip.sh in spirit.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/message_trace_test.exs"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[[ -f "$test_file" ]] ||
	fail "tests/integration/message_trace_test.exs is missing; M6 verification requires it"

for name in \
	e2e_runtime_records_elixir_task_messages \
	e2e_runtime_records_erlang_spawn_messages \
	e2e_runtime_trace_delivered_flush_barrier; do
	grep -Fq "\"$name\"" "$test_file" ||
		fail "$test_file must contain test \"$name\""
done

# All three M6 tests must launch the real recorder binary; refuse silent
# skips that swap in a mock recorder.
grep -Fq 'recorder_binary!' "$test_file" ||
	fail "message_trace_test must call recorder_binary! — no mock recorder allowed"

# Real BEAM fixtures must be referenced so each test path exercises real
# multi-process tracing.
grep -Fq 'test-programs/elixir/task_messages' "$test_file" ||
	fail "message_trace_test must drive the Elixir task_messages fixture"
grep -Fq 'test-programs/erlang/spawn_messages' "$test_file" ||
	fail "message_trace_test must drive the Erlang spawn_messages fixture"

# CTFS bundle queries must go through the recorder binary's
# read-bundle-summary subcommand (which wraps NimTraceReaderHandle).
grep -Fq 'read-bundle-summary' "$test_file" ||
	fail "message_trace_test must verify CTFS bundles via the read-bundle-summary recorder subcommand"

# M6-specific reader assertions: process/thread lifecycle counts, send/recv
# counts, structured event_log_records, and the trace_delivered shutdown
# barrier must all be covered.
for token in \
	'thread_start_count' \
	'thread_switch_count' \
	'thread_exit_count' \
	'process_spawn_count' \
	'process_exit_count' \
	'send_event_count' \
	'receive_event_count' \
	'event_log_records' \
	'sidecar_trace_delivered' \
	'trace_delivered'; do
	grep -Fq "$token" "$test_file" ||
		fail "message_trace_test must assert on $token"
done

# Determinism evidence: the flood test must assert exact ordered content,
# not just a count, so any silent drop surfaces.
grep -Fq 'flush_ping' "$test_file" ||
	fail "message_trace_test must assert on flush_ping ordering for the trace_delivered barrier verification"

# Goldens must exist so the assertions remain anchored to a hand-derived
# first-principles contract.
for golden in \
	'tests/goldens/task_messages/first-principles.org' \
	'tests/goldens/spawn_messages/first-principles.org'; do
	[[ -f "$repo_root/$golden" ]] ||
		fail "$golden is missing; M6 first-principles golden must be checked in"
done

# Refuse common silent-skip patterns: ExUnit @tag :skip, or env-var bail-outs.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
	fail "message_trace_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
	fail "message_trace_test must not bail out via env var"
fi

# Confirm the Justfile wires the test into `just test` so CI cannot miss it.
if ! grep -F 'tests/integration/message_trace_test.exs' "$repo_root/Justfile" >/dev/null; then
	fail "Justfile must run tests/integration/message_trace_test.exs as part of \`just test-integration\`"
fi

# Fixture files must define the deterministic main entrypoints used by the
# tests; otherwise the test would record an unrelated program.
task_fixture="$repo_root/test-programs/elixir/task_messages/lib/task_messages.ex"
[[ -f "$task_fixture" ]] || fail "task_messages fixture is missing at $task_fixture"
grep -Fq 'TaskMessages' "$task_fixture" ||
	fail "$task_fixture must define the TaskMessages module"
grep -Fq 'Task.async' "$task_fixture" ||
	fail "$task_fixture must use Task.async/1 to exercise spawned-process tracing"

spawn_fixture="$repo_root/test-programs/erlang/spawn_messages/src/spawn_messages.erl"
[[ -f "$spawn_fixture" ]] || fail "spawn_messages fixture is missing at $spawn_fixture"
grep -Fq 'spawn_messages' "$spawn_fixture" ||
	fail "$spawn_fixture must define the spawn_messages module"
grep -Eq '^[[:space:]]*main\(\)[[:space:]]*->' "$spawn_fixture" ||
	fail "$spawn_fixture must define main/0 deterministic entrypoint"
grep -Eq '^[[:space:]]*flood\(\)[[:space:]]*->' "$spawn_fixture" ||
	fail "$spawn_fixture must define flood/0 high-volume entrypoint for the trace_delivered barrier test"

# The fixtures must NOT use timer:sleep / Process.sleep for ordering — the
# determinism contract requires explicit handshake-based synchronization.
if grep -Eq 'timer:sleep|Process\.sleep' "$task_fixture" "$spawn_fixture"; then
	fail "task_messages/spawn_messages fixtures must not use sleep-based ordering; use receive-based handshakes"
fi

printf 'PASS: verify_message_trace_test_no_silent_skip\n'
