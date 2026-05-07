#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"
trace_format_dir="$workspace_root/codetracer-trace-format"
expected_sha="e4a7732a55302d19665251b829c8cb82909ac529"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -d "$trace_format_dir/.git" ]] || fail "missing sibling checkout: $trace_format_dir"

actual_sha="$(git -C "$trace_format_dir" rev-parse HEAD)"
[[ "$actual_sha" == "$expected_sha" ]] || fail "codetracer-trace-format HEAD is $actual_sha, expected $expected_sha"

cd "$repo_root"

if [[ "${CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL:-0}" != "1" ]] &&
  (! command -v cargo >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1); then
  if command -v direnv >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL=1 \
      exec direnv exec "$repo_root" bash "$0" "$@"
  fi

  if command -v nix >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL=1 \
      exec nix develop "$repo_root" --command bash "$0" "$@"
  fi

  fail "cargo and jq are required; enter the dev shell or install direnv/nix"
fi

grep -Fq 'codetracer_trace_writer_nim = { path = "../codetracer-trace-format/codetracer_trace_writer_nim" }' Cargo.toml ||
  fail "Cargo.toml must source codetracer_trace_writer_nim from the pinned sibling path"

grep -Fq 'codetracer_trace_reader = { path = "../codetracer-trace-format/codetracer_trace_reader" }' Cargo.toml ||
  fail "Cargo.toml must source codetracer_trace_reader from the pinned sibling path"

metadata="$(cargo metadata --locked --format-version 1)"

printf '%s\n' "$metadata" |
  jq -e --arg root "$workspace_root" '
    [.packages[]
      | select(.name == "codetracer_trace_writer_nim" or .name == "codetracer_trace_reader" or .name == "codetracer_trace_writer")
      | .manifest_path
      | startswith($root + "/codetracer-trace-format/")]
    | length == 3 and all
  ' >/dev/null ||
  fail "Cargo metadata did not resolve trace writer/reader crates from the sibling codetracer-trace-format checkout"

printf 'PASS: codetracer-trace-format dependency is pinned to %s and resolved from the sibling checkout\n' "$expected_sha"
