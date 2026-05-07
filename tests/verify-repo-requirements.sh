#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'PASS: %s\n' "$*"
}

require_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    pass "file exists: $path"
  else
    fail "missing file: $path"
  fi
}

require_executable() {
  local path="$1"
  if [[ -x "$path" && -f "$path" ]]; then
    pass "executable file exists: $path"
  else
    fail "missing executable file: $path"
  fi
}

require_symlink_target() {
  local path="$1"
  local target="$2"
  if [[ -L "$path" && "$(readlink "$path")" == "$target" ]]; then
    pass "symlink $path -> $target"
  else
    fail "expected symlink $path -> $target"
  fi
}

require_text() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if grep -Eq -- "$pattern" "$path"; then
    pass "$description"
  else
    fail "$description"
  fi
}

require_just_recipe() {
  local recipe="$1"
  if just --list --unsorted 2>/dev/null | awk '{print $1}' | sed 's/:$//' | grep -Fxq "$recipe"; then
    pass "Justfile recipe exists: $recipe"
  else
    fail "missing Justfile recipe: $recipe"
  fi
}

require_json_sha() {
  local repo="$1"
  local sha="$2"
  if grep -Eq "\"$repo\"[[:space:]]*:[[:space:]]*\"$sha\"" .github/sibling-pins.json; then
    pass "sibling pin $repo is $sha"
  else
    fail "sibling pin $repo does not match $sha"
  fi
}

require_file flake.nix
require_file .envrc
require_file Justfile
require_file AGENTS.md
require_file Cargo.toml
require_file Cargo.lock
require_file .github/workflows/ci.yml
require_file .github/sibling-pins.json
require_executable tests/verify-repo-requirements.sh
require_executable tests/verify-golden-contract.sh
require_executable tests/verify-trace-format-dependency.sh
require_executable tests/fixtures/run-elixir-canonical-flow.sh
require_executable tests/fixtures/run-erlang-canonical-flow.sh

require_text .envrc '^use flake$' ".envrc uses flake"

require_text flake.nix 'nixos-modules\.url = "github:metacraft-labs/nixos-modules";' "flake uses shared nixos-modules input"
require_text flake.nix 'nixpkgs\.follows = "nixos-modules/nixpkgs-unstable";' "flake nixpkgs follows nixos-modules/nixpkgs-unstable"
require_text flake.nix 'flake-parts\.follows = "nixos-modules/flake-parts";' "flake-parts follows shared input"
require_text flake.nix 'git-hooks\.follows = "nixos-modules/git-hooks-nix";' "git-hooks follows shared input"
require_text flake.nix '"x86_64-linux"' "flake supports x86_64-linux"
require_text flake.nix '"aarch64-linux"' "flake supports aarch64-linux"
require_text flake.nix '"x86_64-darwin"' "flake supports x86_64-darwin"
require_text flake.nix '"aarch64-darwin"' "flake supports aarch64-darwin"
require_text flake.nix 'devShells\.default' "flake exports devShells.\${system}.default through flake-parts"
require_text flake.nix 'packages\.default' "flake exports packages.\${system}.default through flake-parts"
require_text flake.nix 'packages\.codetracer-beam-recorder' "flake exports named recorder package"
require_text flake.nix 'mkBeamRecorderPackage' "flake exports lib.mkBeamRecorderPackage"
require_text flake.nix 'check-added-large-files\.enable = true;' "pre-commit includes large-file check"
require_text flake.nix 'check-merge-conflicts\.enable = true;' "pre-commit includes merge-conflict check"
require_text flake.nix 'entry = "just lint";' "pre-commit includes just lint hook"

for recipe in build test lint format fmt t build-native test-elixir test-erlang test-rust test-goldens test-integration verify-trace-format-dependency bench bump-version; do
  require_just_recipe "$recipe"
done

require_text .github/workflows/ci.yml '^  test:' "CI has test job"
require_text .github/workflows/ci.yml '^  lint:' "CI has lint job"
require_text .github/workflows/ci.yml '^  nix-build:' "CI has nix-build job"
require_text .github/workflows/ci.yml 'just test' "CI test job uses just test"
require_text .github/workflows/ci.yml 'just lint' "CI lint job uses just lint"
require_text .github/workflows/ci.yml 'nix build \.#default' "CI nix-build job builds default package"
require_text .github/workflows/ci.yml 'actions/upload-artifact@v4' "CI uploads full logs as artifacts"

require_symlink_target CLAUDE.md AGENTS.md
require_symlink_target .github/copilot-instructions.md ../AGENTS.md

version="$(grep -E '^version = "' Cargo.toml | head -n1 | cut -d '"' -f2)"
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "Cargo.toml version contains semver"
else
  fail "Cargo.toml version must contain semver"
fi

require_text Justfile 'bump-version new_version:' "Justfile has bump-version recipe"

require_json_sha codetracer 1cf386d69b53dd2c5bf9ec84fb87581e35404822
require_json_sha codetracer-trace-format 5510db82cf7b937c74c84d12e1dced07585943f5

require_text src/main.rs 'codetracer-beam-recorder' "CLI binary identifies recorder name"
require_text src/main.rs '--out-dir' "CLI help documents --out-dir"
require_text src/main.rs '--format' "CLI help documents --format"
require_text src/main.rs 'CODETRACER_BEAM_RECORDER_OUT_DIR' "CLI documents recorder out-dir environment variable"
require_text src/main.rs 'CODETRACER_FORMAT' "CLI documents trace format environment variable"
require_text src/main.rs 'CODETRACER_BEAM_RECORDER_DISABLED' "CLI handles disabled environment variable"

if [[ "$failures" -gt 0 ]]; then
  printf '\n%s compliance check(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll repository requirement checks passed.\n'
