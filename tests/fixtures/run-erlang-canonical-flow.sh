#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$repo_root/test-programs/erlang/canonical_flow"
build_dir="$(mktemp -d)"
ebin_dir="$build_dir/ebin"

cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT

command -v erlc >/dev/null 2>&1 || {
  printf 'FAIL: erlc is required to compile the canonical Erlang fixture\n' >&2
  exit 1
}

command -v erl >/dev/null 2>&1 || {
  printf 'FAIL: erl is required to run the canonical Erlang fixture\n' >&2
  exit 1
}

mkdir -p "$ebin_dir"

erlc +debug_info -o "$ebin_dir" "$fixture_dir/src/canonical_flow.erl"
erlc +debug_info -I "$fixture_dir/test" -o "$ebin_dir" "$fixture_dir/test/canonical_flow_tests.erl"

eunit_output="$(
  erl -noshell -pa "$ebin_dir" \
    -eval 'case eunit:test(canonical_flow_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.' 2>&1
)"
printf '%s\n' "$eunit_output"
if ! grep -Fq 'compute_returns_canonical_result_test' <<<"$eunit_output"; then
  printf 'FAIL: expected EUnit to run compute_returns_canonical_result_test\n' >&2
  exit 1
fi

run_output="$(erl -noshell -pa "$ebin_dir" -s canonical_flow main -s init stop)"
if [[ "$run_output" != "94" ]]; then
  printf 'FAIL: expected Erlang fixture stdout to be "94", got "%s"\n' "$run_output" >&2
  exit 1
fi

printf 'Erlang canonical_flow fixture compiled, tested, and ran with stdout 94.\n'
