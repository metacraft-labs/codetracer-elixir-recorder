#!/usr/bin/env bash
set -euo pipefail

# Guards that tests/integration/manifest_source_location_test.exs cannot
# quietly turn itself into a no-op: every M7 verification entry must drive
# the real recorder binary, real BEAM toolchain, real on-disk manifest +
# source-map artifacts, and the read-bundle-summary reader bridge.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/manifest_source_location_test.exs"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/manifest_source_location_test.exs is missing; M7 verification requires it"

# All three M7 verification entry test names must appear verbatim so the
# milestones plan and the test file stay in sync.
for name in \
  e2e_manifest_loaded_by_runtime_session \
  e2e_source_location_resolution_real_files \
  e2e_source_map_sparse_override_real_trace; do
  grep -Fq "\"$name\"" "$test_file" ||
    fail "$test_file must contain test \"$name\""
done

grep -Fq 'recorder_binary!' "$test_file" ||
  fail "manifest_source_location_test must call recorder_binary! — no mock recorder allowed"

# The three verification fixtures must drive real on-disk fixtures, so the
# test cannot regress into a synthesized-trace placeholder.
grep -Fq 'test-programs/elixir/canonical_flow' "$test_file" ||
  fail "manifest_source_location_test must drive the Elixir canonical_flow fixture"
grep -Fq 'test-programs/erlang/canonical_flow' "$test_file" ||
  fail "manifest_source_location_test must drive the Erlang canonical_flow fixture"
grep -Fq 'test-programs/erlang/generated_source_map' "$test_file" ||
  fail "manifest_source_location_test must drive the generated_source_map fixture"

# Bundle queries must go through read-bundle-summary so the assertions
# read through NimTraceReaderHandle, not raw CTFS bytes.
grep -Fq 'read-bundle-summary' "$test_file" ||
  fail "manifest_source_location_test must verify CTFS bundles via the read-bundle-summary recorder subcommand"

# Manifest-loaded contract assertions: schema, encoding, persistent_term key,
# manifest paths must all be touched.
for token in \
  'manifest_count' \
  'manifest_modules' \
  'manifest_loaded_records' \
  'manifest_loaded_event' \
  'codetracer.beam.module-manifest.v1' \
  'persistent_term_key' \
  'beam-manifest-v1:Elixir.CanonicalFlow' \
  'manifest_paths' \
  'File.exists?' \
  'File.read!' \
  'metadata_contract' \
  'source_location_resolver_order' \
  'source_map' \
  'erl_anno' \
  'module_file_fallback' \
  'unknown_generated_fallback' \
  'canonical_flow.ex' \
  'original_generated.ex' \
  'files/lib/original_generated.ex' \
  'mapped-ok:42' \
  '001-src_generated_bridge.erl.json'; do
  grep -Fq "$token" "$test_file" ||
    fail "manifest_source_location_test must assert on $token"
done

# Refuse common silent-skip patterns: ExUnit @tag :skip, or env-var bail-outs.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "manifest_source_location_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "manifest_source_location_test must not bail out via env var"
fi

# Confirm the Justfile wires the test into `just test` so CI cannot miss it.
if ! grep -F 'tests/integration/manifest_source_location_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/manifest_source_location_test.exs as part of \`just test-integration\`"
fi

# The fixture files referenced from the test must exist on disk so the
# real-recorder runs are reproducible.
[[ -f "$repo_root/test-programs/erlang/generated_source_map/src/generated_bridge.erl" ]] ||
  fail "generated_source_map source fixture is missing"
[[ -f "$repo_root/test-programs/erlang/generated_source_map/source_maps/generated_bridge.json" ]] ||
  fail "generated_source_map source-map fixture is missing"
[[ -f "$repo_root/test-programs/erlang/generated_source_map/lib/original_generated.ex" ]] ||
  fail "generated_source_map original Elixir source is missing"

# The source map JSON must have the v1 schema literal — the resolver
# rejects anything else, so a corrupted fixture would make the test skip.
grep -Fq 'codetracer.beam.sourcemap.v1' \
  "$repo_root/test-programs/erlang/generated_source_map/source_maps/generated_bridge.json" ||
  fail "generated_source_map fixture must declare schema codetracer.beam.sourcemap.v1"

printf 'PASS: verify_manifest_source_location_test_no_silent_skip\n'
