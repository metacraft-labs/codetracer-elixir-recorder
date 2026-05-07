#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/prepare-elixir-fixture.sh [OUTPUT_DIR]

Records the recorder-owned canonical Elixir Mix fixture with the real
codetracer-elixir-recorder and writes a CTFS trace fixture to OUTPUT_DIR.

Environment:
  ELIXIR_FIXTURE_OUTPUT_DIR       Output directory if OUTPUT_DIR is omitted.
  CODETRACER_ELIXIR_RECORDER_PATH Recorder repo override.
  CODETRACER_ELIXIR_RECORDER_BIN  Recorder binary override.
  CODETRACER_ELIXIR_FLOW_TEST     Canonical Mix project override.
  FORCE=1                         Regenerate even when fixture exists.
  CI=1                            Always regenerate; never reuse existing output.
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_repo_root="$(cd "$script_dir/.." && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

output_dir="${1:-${ELIXIR_FIXTURE_OUTPUT_DIR:-$script_repo_root/target/fixtures/elixir-canonical-flow}}"

if [[ -n "${CODETRACER_ELIXIR_RECORDER_PATH:-}" ]]; then
  recorder_repo="$CODETRACER_ELIXIR_RECORDER_PATH"
  [[ -d "$recorder_repo" ]] ||
    fail "CODETRACER_ELIXIR_RECORDER_PATH does not exist: $recorder_repo"
else
  recorder_repo="$script_repo_root"
fi
recorder_repo="$(cd "$recorder_repo" && pwd)"

canonical_project="${CODETRACER_ELIXIR_FLOW_TEST:-$recorder_repo/test-programs/elixir/canonical_flow}"
[[ -f "$canonical_project/mix.exs" ]] ||
  fail "canonical Elixir Mix fixture not found: $canonical_project"

find_recorder_bin() {
  if [[ -n "${CODETRACER_ELIXIR_RECORDER_BIN:-}" ]]; then
    [[ -x "$CODETRACER_ELIXIR_RECORDER_BIN" ]] ||
      fail "CODETRACER_ELIXIR_RECORDER_BIN is not executable: $CODETRACER_ELIXIR_RECORDER_BIN"
    printf '%s\n' "$CODETRACER_ELIXIR_RECORDER_BIN"
    return
  fi

  if command -v codetracer-elixir-recorder >/dev/null 2>&1; then
    command -v codetracer-elixir-recorder
    return
  fi

  for candidate in \
    "$recorder_repo/target/debug/codetracer-elixir-recorder" \
    "$recorder_repo/target/release/codetracer-elixir-recorder"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  fail "codetracer-elixir-recorder binary not found; build the recorder or set CODETRACER_ELIXIR_RECORDER_BIN"
}

recorder_bin="$(find_recorder_bin)"
recorder_bin_dir="$(cd "$(dirname "$recorder_bin")" && pwd)"

if { ! command -v elixirc >/dev/null 2>&1 || ! command -v mix >/dev/null 2>&1; } &&
  [[ "${CODETRACER_ELIXIR_FIXTURE_IN_RECORDER_ENV:-0}" != "1" ]]; then
  if [[ -f "$recorder_repo/.envrc" ]] && command -v direnv >/dev/null 2>&1; then
    exec env CODETRACER_ELIXIR_FIXTURE_IN_RECORDER_ENV=1 \
      direnv exec "$recorder_repo" bash "$script_dir/prepare-elixir-fixture.sh" "$output_dir"
  fi
  if command -v nix >/dev/null 2>&1 && [[ -f "$recorder_repo/flake.nix" ]]; then
    exec env CODETRACER_ELIXIR_FIXTURE_IN_RECORDER_ENV=1 \
      nix develop "$recorder_repo" -c bash "$script_dir/prepare-elixir-fixture.sh" "$output_dir"
  fi
fi

if [[ -d "$output_dir" && "${FORCE:-0}" != "1" && -z "${CI:-}" ]]; then
  if [[ -f "$output_dir/trace_metadata.json" ]] &&
     [[ -f "$output_dir/trace_paths.json" ]] &&
     find "$output_dir" -maxdepth 1 -name '*.ct' -type f | grep -q .; then
    printf 'Elixir fixture already exists at %s; set FORCE=1 to regenerate.\n' "$output_dir"
    exit 0
  fi
fi

parent_dir="$(dirname "$output_dir")"
mkdir -p "$parent_dir"

tmp_root="${TMPDIR:-$parent_dir/.tmp}"
mkdir -p "$tmp_root"
work_dir="$(mktemp -d "$tmp_root/codetracer-elixir-fixture.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

task_ebin="$work_dir/task-ebin"
mix_build_root="$work_dir/mix-build"
build_dir="$work_dir/codetracer-build"
mkdir -p "$task_ebin"

task_sources=(
  "$recorder_repo/lib/codetracer_elixir_recorder/elixir_source_map.ex"
  "$recorder_repo/lib/mix/tasks/compile.codetracer.ex"
  "$recorder_repo/lib/mix/tasks/codetracer.record.ex"
)

for source in "${task_sources[@]}"; do
  [[ -f "$source" ]] || fail "required Mix task source missing: $source"
done

command -v elixirc >/dev/null 2>&1 || fail "elixirc is required to prepare the Elixir fixture"
command -v mix >/dev/null 2>&1 || fail "mix is required to prepare the Elixir fixture"

printf 'Compiling CodeTracer Mix tasks from %s\n' "$recorder_repo"
elixirc -o "$task_ebin" "${task_sources[@]}"

rm -rf "$output_dir"
mkdir -p "$output_dir"

task_ebin_arg="-pa $task_ebin"
printf 'Recording canonical Elixir fixture from %s\n' "$canonical_project"
(
  cd "$canonical_project"
  env \
    MIX_ENV=test \
    MIX_BUILD_ROOT="$mix_build_root" \
    TMPDIR="$tmp_root" \
    CODETRACER_ELIXIR_RECORDER_ROOT="$recorder_repo" \
    CODETRACER_ELIXIR_RECORDER_BIN="$recorder_bin" \
    PATH="$recorder_bin_dir:$PATH" \
    ERL_FLAGS="$task_ebin_arg" \
    ELIXIR_ERL_OPTIONS="$task_ebin_arg" \
    mix codetracer.record \
      --build-dir "$build_dir" \
      --out-dir "$output_dir" \
      --format ctfs \
      --include-module Elixir.CanonicalFlow \
      --eval 'CanonicalFlow.main()'
)

canonical_source="$canonical_project/lib/canonical_flow.ex"
if [[ ! -f "$output_dir/trace_metadata.json" ]]; then
  escaped_project="$(json_escape "$canonical_project")"
  cat >"$output_dir/trace_metadata.json" <<EOF
{
  "program": "$escaped_project",
  "args": ["CanonicalFlow.main()"],
  "workdir": "$escaped_project"
}
EOF
fi

if [[ ! -f "$output_dir/trace_paths.json" ]]; then
  escaped_source="$(json_escape "$canonical_source")"
  cat >"$output_dir/trace_paths.json" <<EOF
["$escaped_source"]
EOF
fi

absolute_project_copy="$output_dir/files/${canonical_project#/}"
mkdir -p "$(dirname "$absolute_project_copy")"
rm -rf "$absolute_project_copy"
cp -R "$canonical_project" "$absolute_project_copy"

[[ -f "$output_dir/trace_metadata.json" ]] ||
  fail "fixture generation did not produce trace_metadata.json in $output_dir"
[[ -f "$output_dir/trace_paths.json" ]] ||
  fail "fixture generation did not produce trace_paths.json in $output_dir"
find "$output_dir" -maxdepth 1 -name '*.ct' -type f | grep -q . ||
  fail "fixture generation did not produce a CTFS .ct file in $output_dir"
[[ -f "$output_dir/files/lib/canonical_flow.ex" ]] ||
  fail "fixture generation did not copy canonical Elixir source into $output_dir/files"
[[ -f "$absolute_project_copy/lib/canonical_flow.ex" ]] ||
  fail "fixture generation did not copy canonical Elixir source into $absolute_project_copy"

cat >"$output_dir/M15-FIXTURE.md" <<'EOF'
# Elixir Canonical UI Fixture

This fixture is generated from the recorder-owned canonical Mix program with
the real codetracer-elixir-recorder. M15 UI and VS Code smoke tests regenerate
the trace from source in CI instead of storing full trace artifacts as goldens.
EOF

printf 'Elixir canonical trace fixture ready: %s\n' "$output_dir"
