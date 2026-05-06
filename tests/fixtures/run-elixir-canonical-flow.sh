#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$repo_root/test-programs/elixir/canonical_flow"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-elixir-fixture-build.XXXXXX")"

cleanup() {
  rm -rf "$build_root"
}
trap cleanup EXIT

command -v elixir >/dev/null 2>&1 || {
  printf 'FAIL: elixir is required to run the canonical Elixir fixture\n' >&2
  exit 1
}

command -v mix >/dev/null 2>&1 || {
  printf 'FAIL: mix is required to compile and test the canonical Elixir fixture\n' >&2
  exit 1
}

cd "$fixture_dir"

env MIX_ENV=test MIX_BUILD_ROOT="$build_root" mix clean
env MIX_ENV=test MIX_BUILD_ROOT="$build_root" mix compile --warnings-as-errors

test_output="$(env MIX_ENV=test MIX_BUILD_ROOT="$build_root" mix test --no-color 2>&1)"
printf '%s\n' "$test_output"
if ! grep -Fq '1 test, 0 failures' <<<"$test_output"; then
  printf 'FAIL: expected exactly one passing ExUnit fixture test\n' >&2
  exit 1
fi

run_output="$(env MIX_ENV=test MIX_BUILD_ROOT="$build_root" mix run --no-compile -e 'CanonicalFlow.main()')"
if [[ "$run_output" != "94" ]]; then
  printf 'FAIL: expected Elixir fixture stdout to be "94", got "%s"\n' "$run_output" >&2
  exit 1
fi

printf 'Elixir canonical_flow fixture compiled, tested, and ran with stdout 94.\n'
