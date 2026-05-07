#!/usr/bin/env bash
set -euo pipefail

# Guards that tests/integration/step_instrumentation_test.exs cannot quietly
# turn itself into a no-op: every M8 assertion path must require the recorder
# binary, real `erl`/`erlc`, the canonical / generated-source-map /
# tail-recursion fixtures, and the M8 transformed-forms dump.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/step_instrumentation_test.exs"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[[ -f "$test_file" ]] ||
	fail "tests/integration/step_instrumentation_test.exs is missing; M8 verification requires it"

grep -Fq 'e2e_instrumented_erlang_steps_match_golden' "$test_file" ||
	fail "$test_file must contain test \"e2e_instrumented_erlang_steps_match_golden\""

grep -Fq 'e2e_instrumented_elixir_generated_steps_match_original_source' "$test_file" ||
	fail "$test_file must contain test \"e2e_instrumented_elixir_generated_steps_match_original_source\""

grep -Fq 'e2e_tail_recursion_semantics_preserved' "$test_file" ||
	fail "$test_file must contain test \"e2e_tail_recursion_semantics_preserved\""

# The test must launch the real recorder binary against the real BEAM
# toolchain. Refuse mocks.
grep -Fq 'recorder_binary!' "$test_file" ||
	fail "step_instrumentation_test must call recorder_binary! — no mock recorder allowed"

grep -Fq '"erl"' "$test_file" ||
	fail "step_instrumentation_test must launch erl for the BEAM fixtures"

grep -Fq '"erlc"' "$test_file" ||
	fail "step_instrumentation_test must compile fixtures with erlc"

# Must read back the bundle through the documented reader subcommand.
grep -Fq 'read-bundle-summary' "$test_file" ||
	fail "step_instrumentation_test must verify CTFS bundles via the read-bundle-summary recorder subcommand"

# Must verify on-disk M8 transformed-forms dump for the no-post-tail-call
# contract.
grep -Fq 'recorder_metadata/transformed_forms' "$test_file" ||
	fail "step_instrumentation_test must inspect recorder_metadata/transformed_forms/ for the tail-call contract"

# Must verify the per-source-line oracle from the first-principles golden.
grep -Fq 'first-principles' "$test_file" ||
	fail "step_instrumentation_test must reference the first-principles golden as the per-line oracle"

# Must verify source-map resolution for generated Erlang.
grep -Fq 'source_map' "$test_file" ||
	fail "step_instrumentation_test must verify generated_bridge steps resolve via the source_map override"

# Must verify uninstrumented-vs-instrumented stdout/exit-code parity for the
# tail-recursion contract.
grep -Fq 'uninstrumented_status' "$test_file" ||
	fail "step_instrumentation_test must compare uninstrumented and instrumented exit codes for the tail-recursion fixture"

# Refuse common silent-skip patterns: ExUnit @tag :skip, or env-var bail-outs.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
	fail "step_instrumentation_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
	fail "step_instrumentation_test must not bail out via env var"
fi

# Confirm the Justfile wires the test into `just test-integration` so CI
# cannot miss it.
if ! grep -F 'tests/integration/step_instrumentation_test.exs' "$repo_root/Justfile" >/dev/null; then
	fail "Justfile must run tests/integration/step_instrumentation_test.exs as part of \`just test-integration\`"
fi

printf 'PASS: verify_step_instrumentation_test_no_silent_skip\n'
