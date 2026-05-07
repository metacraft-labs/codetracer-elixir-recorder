#!/usr/bin/env bash
set -euo pipefail

# M17 verification guard for tests/integration/plug_smoke_test.exs.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/plug_smoke_test.exs"
fixture_dir="$repo_root/test-programs/elixir/plug_smoke"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/plug_smoke_test.exs is missing; M17 verification requires it"

[[ -d "$fixture_dir" ]] ||
  fail "test-programs/elixir/plug_smoke fixture missing"

[[ -f "$fixture_dir/mix.exs" ]] ||
  fail "test-programs/elixir/plug_smoke/mix.exs missing"

[[ -f "$fixture_dir/lib/plug_smoke.ex" ]] ||
  fail "test-programs/elixir/plug_smoke/lib/plug_smoke.ex missing"

[[ -f "$fixture_dir/lib/plug_smoke/router.ex" ]] ||
  fail "test-programs/elixir/plug_smoke/lib/plug_smoke/router.ex missing"

grep -Fq 'e2e_phoenix_or_plug_smoke_real_trace' "$test_file" ||
  fail "$test_file must contain test \"e2e_phoenix_or_plug_smoke_real_trace\""

grep -Fq 'recorder_binary!' "$test_file" ||
  fail "plug_smoke_test must call recorder_binary! — no mock recorder allowed"

grep -Fq '"mix"' "$test_file" ||
  fail "plug_smoke_test must launch real mix to drive the request fixture"

grep -Fq 'read-bundle-summary' "$test_file" ||
  fail "plug_smoke_test must verify CTFS bundles via read-bundle-summary"

# The handler call sequence is the load-bearing assertion.
grep -Fq ':route in handler_calls' "$test_file" ||
  fail "plug_smoke_test must assert PlugSmoke.Router.route was traced"

grep -Fq ':dispatch in handler_calls' "$test_file" ||
  fail "plug_smoke_test must assert PlugSmoke.Router.dispatch was traced"

grep -Fq ':render in handler_calls' "$test_file" ||
  fail "plug_smoke_test must assert PlugSmoke.Router.render was traced"

# Refuse silent-skip patterns.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "plug_smoke_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "plug_smoke_test must not bail out via env var"
fi

if ! grep -F 'tests/integration/plug_smoke_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/plug_smoke_test.exs as part of \`just test-integration\`"
fi

printf 'PASS: verify_plug_smoke_test_no_silent_skip\n'
