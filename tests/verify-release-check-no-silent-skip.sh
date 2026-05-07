#!/usr/bin/env bash
set -euo pipefail

# M17 verification guard for `just release-check`. The release-check
# script is the single command that confirms the recorder is ready to
# publish: package metadata is consistent, version is the single source
# of truth, CHANGELOG and LICENSE exist, and downstream regression
# command surfaces are in place.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/release-check.sh"
justfile="$repo_root/Justfile"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$script" ]] ||
  fail "scripts/release-check.sh is missing; M17 verification requires it"

[[ -x "$script" ]] ||
  fail "scripts/release-check.sh must be executable"

grep -Fq 'release-check:' "$justfile" ||
  fail "Justfile must declare a release-check recipe"

# The release-check script must enforce these load-bearing checks.
for token in \
  'Cargo.toml' \
  'mix.exs' \
  'rebar3_codetracer.app.src' \
  'CHANGELOG.md' \
  'LICENSE' \
  'codetracer-trace-format' \
  'codetracer-beam-recorder'; do
  grep -Fq "$token" "$script" ||
    fail "release-check.sh must reference '$token'"
done

# Version consistency: the script must validate the Cargo version is
# the single source of truth.
grep -Fq 'version' "$script" ||
  fail "release-check.sh must verify version consistency"

[[ -f "$repo_root/CHANGELOG.md" ]] ||
  fail "CHANGELOG.md must exist at the repo root"

[[ -f "$repo_root/LICENSE" ]] ||
  fail "LICENSE must exist at the repo root"

if ! grep -F 'just release-check' "$justfile" >/dev/null && ! grep -E 'release-check:' "$justfile" >/dev/null; then
  fail "Justfile must wire \`just release-check\`"
fi

printf 'PASS: verify_release_check_no_silent_skip\n'
