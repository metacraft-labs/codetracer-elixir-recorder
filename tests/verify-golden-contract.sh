#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

golden_dir="tests/goldens/canonical_flow"
org_file="$golden_dir/first-principles.org"
json_file="$golden_dir/expected_trace_summary.json"
elixir_source="test-programs/elixir/canonical_flow/lib/canonical_flow.ex"
erlang_source="test-programs/erlang/canonical_flow/src/canonical_flow.erl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required to validate expected_trace_summary.json"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing required file: $path"
}

require_text() {
  local path="$1"
  local pattern="$2"
  local description="$3"

  if ! grep -Eq -- "$pattern" "$path"; then
    fail "$description"
  fi
}

require_source_line() {
  local path="$1"
  local line="$2"
  local expected="$3"
  local actual

  actual="$(sed -n "${line}p" "$path" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ "$actual" == "$expected" ]] || fail "$path:$line expected '$expected', found '$actual'"
}

require_org_source_line() {
  local marker="$1"
  local expected="$2"

  awk -v marker="$marker" -v expected="$expected" \
    'index($0, marker) && index($0, expected) { found = 1 } END { exit found ? 0 : 1 }' \
    "$org_file" || fail "first-principles.org missing source-location evidence: $marker $expected"
}

require_json_query() {
  local query="$1"
  local description="$2"

  jq -e "$query" "$json_file" >/dev/null || fail "$description"
}

require_json_source_line() {
  local language="$1"
  local line="$2"
  local expected="$3"

  jq -e --argjson line "$line" --arg text "$expected" \
    ".languages.$language.source_location_evidence[] | select(.line == \$line and .text == \$text)" \
    "$json_file" >/dev/null || fail "expected_trace_summary.json missing $language source-location evidence: line $line $expected"
}

require_file "$org_file"
require_file "$json_file"
require_file "$elixir_source"
require_file "$erlang_source"

jq -e . "$json_file" >/dev/null || fail "expected_trace_summary.json must be valid JSON"

derivation_count="$(grep -Ec 'DERIVATION:' "$org_file")"
[[ "$derivation_count" -ge 4 ]] || fail "first-principles.org must contain at least four DERIVATION comments"

require_text "$org_file" 'Source-Location Evidence' "first-principles.org must document source-location evidence"
require_text "$org_file" 'Function Sequence' "first-principles.org must document function sequence"
require_text "$org_file" 'expected stdout: =94\\n=' "first-principles.org must document expected stdout"
require_text "$org_file" 'expected exit code: =0=' "first-principles.org must document expected exit code"
require_text "$org_file" 'Process Relationships' "first-principles.org must document process relationships"

require_text "$json_file" '"hand_authored"[[:space:]]*:[[:space:]]*true' "expected_trace_summary.json must be marked hand-authored"
require_text "$json_file" '"recorder_output_used"[[:space:]]*:[[:space:]]*false' "expected_trace_summary.json must reject recorder-derived output"
require_text "$json_file" '"derivation_comments"' "expected_trace_summary.json must contain derivation comments"
require_text "$json_file" '"source_location_evidence"' "expected_trace_summary.json must contain source-location evidence"
require_text "$json_file" '"expected_stdout"[[:space:]]*:[[:space:]]*"94\\n"' "expected_trace_summary.json must document expected stdout"
require_text "$json_file" '"expected_exit_code"[[:space:]]*:[[:space:]]*0' "expected_trace_summary.json must document expected exit code"

require_json_query '.schema_version == 1' "expected_trace_summary.json must use schema_version 1"
require_json_query '.fixture == "canonical_flow"' "expected_trace_summary.json must identify the canonical_flow fixture"
require_json_query '.hand_authored == true' "expected_trace_summary.json must be marked hand-authored"
require_json_query '.recorder_output_used == false' "expected_trace_summary.json must reject recorder-derived output"
require_json_query '.expected_stdout == "94\n"' "expected_trace_summary.json expected_stdout must be 94 newline"
require_json_query '.expected_exit_code == 0' "expected_trace_summary.json expected_exit_code must be 0"
require_json_query '.value_type_expectations.type_kind == "Int" and .value_type_expectations.lang_type == "integer"' "expected_trace_summary.json must document integer value type expectations"

if grep -Eq '"recorder_output_used"[[:space:]]*:[[:space:]]*true|generated[ _-]?from[ _-]?recorder' "$json_file" "$org_file"; then
  fail "goldens must not be generated from recorder output"
fi

for name in a b sum_val doubled final_result result; do
  require_text "$org_file" "=$name=" "first-principles.org missing variable $name"
  require_text "$json_file" "\"(name|canonical_name)\"[[:space:]]*:[[:space:]]*\"$name\"" "expected_trace_summary.json missing variable $name"
done

for value in 10 32 42 84 94; do
  require_text "$org_file" "[^0-9]${value}[^0-9]" "first-principles.org missing value $value"
  require_text "$json_file" "[^0-9]${value}[^0-9]" "expected_trace_summary.json missing value $value"
done

require_source_line "$elixir_source" 4 "def compute do"
require_org_source_line "canonical_flow.ex:4" "def compute do"
require_json_source_line elixir 4 "def compute do"
require_source_line "$elixir_source" 5 "a = 10"
require_org_source_line "canonical_flow.ex:5" "a = 10"
require_json_source_line elixir 5 "a = 10"
require_source_line "$elixir_source" 6 "b = 32"
require_org_source_line "canonical_flow.ex:6" "b = 32"
require_json_source_line elixir 6 "b = 32"
require_source_line "$elixir_source" 7 "sum_val = a + b"
require_org_source_line "canonical_flow.ex:7" "sum_val = a + b"
require_json_source_line elixir 7 "sum_val = a + b"
require_source_line "$elixir_source" 8 "doubled = sum_val * 2"
require_org_source_line "canonical_flow.ex:8" "doubled = sum_val * 2"
require_json_source_line elixir 8 "doubled = sum_val * 2"
require_source_line "$elixir_source" 9 "final_result = doubled + a"
require_org_source_line "canonical_flow.ex:9" "final_result = doubled + a"
require_json_source_line elixir 9 "final_result = doubled + a"
require_source_line "$elixir_source" 10 "true = final_result == 94"
require_org_source_line "canonical_flow.ex:10" "true = final_result == 94"
require_json_source_line elixir 10 "true = final_result == 94"
require_source_line "$elixir_source" 11 "final_result"
require_org_source_line "canonical_flow.ex:11" "final_result"
require_json_source_line elixir 11 "final_result"
require_source_line "$elixir_source" 14 "def main do"
require_org_source_line "canonical_flow.ex:14" "def main do"
require_json_source_line elixir 14 "def main do"
require_source_line "$elixir_source" 15 "result = compute()"
require_org_source_line "canonical_flow.ex:15" "result = compute()"
require_json_source_line elixir 15 "result = compute()"
require_source_line "$elixir_source" 16 "true = result == 94"
require_org_source_line "canonical_flow.ex:16" "true = result == 94"
require_json_source_line elixir 16 "true = result == 94"
require_source_line "$elixir_source" 17 "IO.puts(result)"
require_org_source_line "canonical_flow.ex:17" "IO.puts(result)"
require_json_source_line elixir 17 "IO.puts(result)"
require_source_line "$elixir_source" 18 "result"
require_org_source_line "canonical_flow.ex:18" "result"
require_json_source_line elixir 18 "result"

require_source_line "$erlang_source" 4 "compute() ->"
require_org_source_line "canonical_flow.erl:4" "compute() ->"
require_json_source_line erlang 4 "compute() ->"
require_source_line "$erlang_source" 5 "A = 10,"
require_org_source_line "canonical_flow.erl:5" "A = 10,"
require_json_source_line erlang 5 "A = 10,"
require_source_line "$erlang_source" 6 "B = 32,"
require_org_source_line "canonical_flow.erl:6" "B = 32,"
require_json_source_line erlang 6 "B = 32,"
require_source_line "$erlang_source" 7 "SumVal = A + B,"
require_org_source_line "canonical_flow.erl:7" "SumVal = A + B,"
require_json_source_line erlang 7 "SumVal = A + B,"
require_source_line "$erlang_source" 8 "Doubled = SumVal * 2,"
require_org_source_line "canonical_flow.erl:8" "Doubled = SumVal * 2,"
require_json_source_line erlang 8 "Doubled = SumVal * 2,"
require_source_line "$erlang_source" 9 "FinalResult = Doubled + A,"
require_org_source_line "canonical_flow.erl:9" "FinalResult = Doubled + A,"
require_json_source_line erlang 9 "FinalResult = Doubled + A,"
require_source_line "$erlang_source" 10 "true = FinalResult =:= 94,"
require_org_source_line "canonical_flow.erl:10" "true = FinalResult =:= 94,"
require_json_source_line erlang 10 "true = FinalResult =:= 94,"
require_source_line "$erlang_source" 11 "FinalResult."
require_org_source_line "canonical_flow.erl:11" "FinalResult."
require_json_source_line erlang 11 "FinalResult."
require_source_line "$erlang_source" 13 "main() ->"
require_org_source_line "canonical_flow.erl:13" "main() ->"
require_json_source_line erlang 13 "main() ->"
require_source_line "$erlang_source" 14 "Result = compute(),"
require_org_source_line "canonical_flow.erl:14" "Result = compute(),"
require_json_source_line erlang 14 "Result = compute(),"
require_source_line "$erlang_source" 15 "true = Result =:= 94,"
require_org_source_line "canonical_flow.erl:15" "true = Result =:= 94,"
require_json_source_line erlang 15 "true = Result =:= 94,"
require_source_line "$erlang_source" 16 "io:format(\"~p~n\", [Result]),"
require_org_source_line "canonical_flow.erl:16" "io:format(\"~p~n\", [Result]),"
require_json_source_line erlang 16 "io:format(\"~p~n\", [Result]),"
require_source_line "$erlang_source" 17 "Result."
require_org_source_line "canonical_flow.erl:17" "Result."
require_json_source_line erlang 17 "Result."

require_json_query '.languages.elixir.function_sequence == [
  {"event": "call", "function": "CanonicalFlow.main/0", "line": 14},
  {"event": "call", "function": "CanonicalFlow.compute/0", "line": 4, "call_site_line": 15},
  {"event": "return", "function": "CanonicalFlow.compute/0", "line": 11, "value": 94},
  {"event": "stdout", "function": "CanonicalFlow.main/0", "line": 17, "content": "94\n"},
  {"event": "return", "function": "CanonicalFlow.main/0", "line": 18, "value": 94}
]' "expected_trace_summary.json Elixir function sequence must match source derivation"
require_json_query '.languages.erlang.function_sequence == [
  {"event": "call", "function": "canonical_flow:main/0", "line": 13},
  {"event": "call", "function": "canonical_flow:compute/0", "line": 4, "call_site_line": 14},
  {"event": "return", "function": "canonical_flow:compute/0", "line": 11, "value": 94},
  {"event": "stdout", "function": "canonical_flow:main/0", "line": 16, "content": "94\n"},
  {"event": "return", "function": "canonical_flow:main/0", "line": 17, "value": 94}
]' "expected_trace_summary.json Erlang function sequence must match source derivation"
require_json_query '.languages.elixir.variables == [
  {"name": "a", "line": 5, "value": 10},
  {"name": "b", "line": 6, "value": 32},
  {"name": "sum_val", "line": 7, "value": 42},
  {"name": "doubled", "line": 8, "value": 84},
  {"name": "final_result", "line": 9, "value": 94},
  {"name": "result", "line": 15, "value": 94}
]' "expected_trace_summary.json Elixir variables must match source derivation"
require_json_query '.languages.erlang.variables == [
  {"name": "A", "canonical_name": "a", "line": 5, "value": 10},
  {"name": "B", "canonical_name": "b", "line": 6, "value": 32},
  {"name": "SumVal", "canonical_name": "sum_val", "line": 7, "value": 42},
  {"name": "Doubled", "canonical_name": "doubled", "line": 8, "value": 84},
  {"name": "FinalResult", "canonical_name": "final_result", "line": 9, "value": 94},
  {"name": "Result", "canonical_name": "result", "line": 14, "value": 94}
]' "expected_trace_summary.json Erlang variables must match source derivation"
require_json_query '.languages.elixir.process_relationships.fixture_owned_process_count == 1
  and (.languages.elixir.process_relationships.spawned_child_processes | length) == 0
  and (.languages.elixir.process_relationships.messages_sent_by_fixture_source | length) == 0
  and .languages.erlang.process_relationships.fixture_owned_process_count == 1
  and (.languages.erlang.process_relationships.spawned_child_processes | length) == 0
  and (.languages.erlang.process_relationships.messages_sent_by_fixture_source | length) == 0' "expected_trace_summary.json process relationships must match source derivation"

printf 'Golden contract validation passed: canonical_flow first-principles oracle is documented and source-backed.\n'
