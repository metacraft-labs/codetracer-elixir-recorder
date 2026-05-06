use std::fs;
use std::io::Cursor;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use codetracer_ctfs::CtfsReader;
use codetracer_trace_types::ValueRecord;
use codetracer_trace_writer_nim::NimTraceReaderHandle;
use serde_json::Value;

fn recorder_binary() -> &'static str {
    env!("CARGO_BIN_EXE_codetracer-elixir-recorder")
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn temp_dir(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before unix epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "codetracer-elixir-recorder-m3-{label}-{}-{nonce}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("create temp dir");
    path
}

fn clean_recorder_command() -> Command {
    let mut command = Command::new(recorder_binary());
    command.env_remove("CODETRACER_ELIXIR_RECORDER_OUT_DIR");
    command.env_remove("CODETRACER_FORMAT");
    command.env_remove("CODETRACER_ELIXIR_RECORDER_DISABLED");
    command
}

fn output_text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn assert_success(output: &Output, context: &str) {
    assert!(
        output.status.success(),
        "{context} failed with status {:?}\n{}",
        output.status.code(),
        output_text(output)
    );
}

struct RecordedTrace {
    out_dir: PathBuf,
    output: Output,
}

fn compile_elixir_fixture(fixture_dir: &Path, build_root: &Path) {
    let clean = Command::new("mix")
        .arg("clean")
        .current_dir(fixture_dir)
        .env("MIX_ENV", "test")
        .env("MIX_BUILD_ROOT", build_root)
        .output()
        .expect("run mix clean");
    assert_success(&clean, "mix clean");

    let compile = Command::new("mix")
        .args(["compile", "--warnings-as-errors"])
        .current_dir(fixture_dir)
        .env("MIX_ENV", "test")
        .env("MIX_BUILD_ROOT", build_root)
        .output()
        .expect("run mix compile");
    assert_success(&compile, "mix compile");
}

fn compile_erlang_fixture(ebin_dir: &Path) {
    fs::create_dir_all(ebin_dir).expect("create ebin dir");
    let fixture_dir = repo_root().join("test-programs/erlang/canonical_flow");

    for source in [
        fixture_dir.join("src/canonical_flow.erl"),
        fixture_dir.join("test/canonical_flow_tests.erl"),
    ] {
        let compile = Command::new("erlc")
            .arg("+debug_info")
            .arg("-o")
            .arg(ebin_dir)
            .arg(&source)
            .output()
            .expect("run erlc");
        assert_success(&compile, &format!("erlc {}", source.display()));
    }
}

fn compile_erlang_spawn_fixture(ebin_dir: &Path) {
    fs::create_dir_all(ebin_dir).expect("create spawn fixture ebin dir");
    let source = repo_root().join("test-programs/erlang/spawn_messages/src/spawn_messages.erl");
    let compile = Command::new("erlc")
        .arg("+debug_info")
        .arg("-o")
        .arg(ebin_dir)
        .arg(&source)
        .output()
        .expect("run erlc for spawn_messages");
    assert_success(&compile, &format!("erlc {}", source.display()));
}

fn compile_erlang_tail_fixture(ebin_dir: &Path) {
    fs::create_dir_all(ebin_dir).expect("create tail fixture ebin dir");
    let source = repo_root().join("test-programs/erlang/tail_recursion/src/tail_recursion.erl");
    let compile = Command::new("erlc")
        .arg("+debug_info")
        .arg("-o")
        .arg(ebin_dir)
        .arg(&source)
        .output()
        .expect("run erlc for tail_recursion");
    assert_success(&compile, &format!("erlc {}", source.display()));
}

fn compile_erlang_branch_fixture(ebin_dir: &Path) {
    fs::create_dir_all(ebin_dir).expect("create branch fixture ebin dir");
    let source = repo_root().join("test-programs/erlang/branch_forms/src/branch_forms.erl");
    let compile = Command::new("erlc")
        .arg("+debug_info")
        .arg("-o")
        .arg(ebin_dir)
        .arg(&source)
        .output()
        .expect("run erlc for branch_forms");
    assert_success(&compile, &format!("erlc {}", source.display()));
}

fn compile_erlang_generated_source_map_fixture(ebin_dir: &Path) {
    fs::create_dir_all(ebin_dir).expect("create generated source-map fixture ebin dir");
    let source =
        repo_root().join("test-programs/erlang/generated_source_map/src/generated_bridge.erl");
    let compile = Command::new("erlc")
        .arg("+debug_info")
        .arg("-o")
        .arg(ebin_dir)
        .arg(&source)
        .output()
        .expect("run erlc for generated_bridge");
    assert_success(&compile, &format!("erlc {}", source.display()));
}

fn record_elixir_expression(label: &str, expression: &str) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let elixir_fixture = repo_root().join("test-programs/elixir/canonical_flow");
    let mix_build_root = tmp.join("mix-build");
    compile_elixir_fixture(&elixir_fixture, &mix_build_root);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "mix",
            "run",
            "--no-compile",
            "-e",
            expression,
        ])
        .current_dir(&elixir_fixture)
        .env("MIX_ENV", "test")
        .env("MIX_BUILD_ROOT", &mix_build_root)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Elixir expression under runtime session");

    RecordedTrace { out_dir, output }
}

fn record_elixir_fixture_expression(
    label: &str,
    fixture_name: &str,
    expression: &str,
) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let elixir_fixture = repo_root().join("test-programs/elixir").join(fixture_name);
    let mix_build_root = tmp.join("mix-build");
    compile_elixir_fixture(&elixir_fixture, &mix_build_root);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "mix",
            "run",
            "--no-compile",
            "-e",
            expression,
        ])
        .current_dir(&elixir_fixture)
        .env("MIX_ENV", "test")
        .env("MIX_BUILD_ROOT", &mix_build_root)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Elixir fixture under runtime session");

    RecordedTrace { out_dir, output }
}

fn record_erlang_canonical_function(label: &str, function: &str) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang/canonical_flow");
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_fixture(&ebin_dir);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir.to_str().unwrap(),
            "-s",
            "canonical_flow",
            function,
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Erlang canonical fixture under runtime session");

    RecordedTrace { out_dir, output }
}

fn record_erlang_spawn_function(label: &str, function: &str) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang/spawn_messages");
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_spawn_fixture(&ebin_dir);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir.to_str().unwrap(),
            "-s",
            "spawn_messages",
            function,
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Erlang spawn fixture under runtime session");

    RecordedTrace { out_dir, output }
}

fn record_erlang_tail_function(label: &str, function: &str) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang/tail_recursion");
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_tail_fixture(&ebin_dir);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir.to_str().unwrap(),
            "-s",
            "tail_recursion",
            function,
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Erlang tail fixture under runtime session");

    RecordedTrace { out_dir, output }
}

fn record_erlang_branch_function(label: &str, function: &str) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang/branch_forms");
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_branch_fixture(&ebin_dir);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir.to_str().unwrap(),
            "-s",
            "branch_forms",
            function,
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Erlang branch fixture under runtime session");

    RecordedTrace { out_dir, output }
}

fn record_erlang_generated_source_map_function(label: &str, function: &str) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang/generated_source_map");
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_generated_source_map_fixture(&ebin_dir);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir.to_str().unwrap(),
            "-s",
            "generated_bridge",
            function,
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run generated source-map fixture under runtime session");

    RecordedTrace { out_dir, output }
}

fn open_mix_trace(out_dir: &Path) -> NimTraceReaderHandle {
    open_named_trace(out_dir, "mix.ct")
}

fn open_named_trace(out_dir: &Path, filename: &str) -> NimTraceReaderHandle {
    let ct_path = out_dir.join(filename);
    assert!(
        ct_path.is_file(),
        "expected CTFS trace at {}",
        ct_path.display()
    );
    NimTraceReaderHandle::open(ct_path.to_str().expect("trace path utf-8"))
        .expect("open runtime CTFS trace through real reader bridge")
}

fn runtime_sidecar_events(out_dir: &Path) -> Vec<Value> {
    let sidecar_path = out_dir.join("runtime_session.jsonl");
    let sidecar = fs::read_to_string(&sidecar_path)
        .unwrap_or_else(|error| panic!("read {}: {error}", sidecar_path.display()));
    sidecar
        .lines()
        .map(|line| serde_json::from_str(line).expect("runtime sidecar JSON line"))
        .collect()
}

fn trace_meta(out_dir: &Path) -> Value {
    let path = out_dir.join("trace_meta.json");
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_str(&text).expect("trace_meta.json")
}

fn manifest_jsons(out_dir: &Path) -> Vec<Value> {
    let root = out_dir.join("recorder_metadata/manifests");
    let mut paths = fs::read_dir(&root)
        .unwrap_or_else(|error| panic!("read {}: {error}", root.display()))
        .map(|entry| entry.expect("manifest entry").path())
        .collect::<Vec<_>>();
    paths.sort();
    paths
        .into_iter()
        .map(|path| {
            let text = fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
            serde_json::from_str(&text).expect("manifest JSON")
        })
        .collect()
}

fn step_location_jsons(out_dir: &Path) -> Vec<Value> {
    let root = out_dir.join("recorder_metadata/step_locations");
    let mut paths = fs::read_dir(&root)
        .unwrap_or_else(|error| panic!("read {}: {error}", root.display()))
        .map(|entry| entry.expect("step location entry").path())
        .collect::<Vec<_>>();
    paths.sort();
    paths
        .into_iter()
        .map(|path| {
            let text = fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
            serde_json::from_str(&text).expect("step locations JSON")
        })
        .collect()
}

fn manifest_location_index(
    out_dir: &Path,
) -> std::collections::HashMap<u64, (String, i64, String)> {
    let mut index = std::collections::HashMap::new();
    for manifest in manifest_jsons(out_dir) {
        let Some(locations) = manifest["locations"].as_array() else {
            continue;
        };
        for location in locations {
            let id = location["id"].as_u64().expect("manifest location id");
            let trace_copy_path = location["trace_copy_path"]
                .as_str()
                .expect("manifest trace copy path")
                .to_string();
            let line = location["line"].as_i64().expect("manifest location line");
            let resolution = location["resolution"]
                .as_str()
                .expect("manifest location resolution")
                .to_string();
            index.insert(id, (trace_copy_path, line, resolution));
        }
    }
    index
}

fn sidecar_step_locations(out_dir: &Path) -> Vec<(String, i64, String)> {
    let locations = manifest_location_index(out_dir);
    runtime_sidecar_events(out_dir)
        .into_iter()
        .filter(|event| event["event"] == "step")
        .map(|event| {
            let id = event["location_id"].as_u64().expect("step location_id");
            locations
                .get(&id)
                .unwrap_or_else(|| panic!("step location_id {id} missing from manifests"))
                .clone()
        })
        .collect()
}

fn assert_ordered_subsequence(observed: &[i64], expected: &[i64]) {
    let mut cursor = 0;
    for line in observed {
        if expected.get(cursor) == Some(line) {
            cursor += 1;
            if cursor == expected.len() {
                return;
            }
        }
    }
    panic!("missing ordered line subsequence {expected:?} in observed lines {observed:?}");
}

fn transformed_dump_text(out_dir: &Path, suffix: &str) -> String {
    let root = out_dir.join("recorder_metadata/transformed_forms");
    let path = fs::read_dir(&root)
        .unwrap_or_else(|error| panic!("read transformed dumps {}: {error}", root.display()))
        .map(|entry| entry.expect("transformed dump entry").path())
        .find(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(suffix))
        })
        .unwrap_or_else(|| {
            panic!(
                "missing transformed dump ending in {suffix} under {}",
                root.display()
            )
        });
    fs::read_to_string(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()))
}

fn raw_ctfs_call_return_values(out_dir: &Path) -> Vec<String> {
    let ct_path = out_dir.join("mix.ct");
    assert!(
        ct_path.is_file(),
        "expected CTFS trace at {}",
        ct_path.display()
    );
    let mut reader = CtfsReader::open(&ct_path).expect("open CTFS container");
    let calls = reader.read_file("calls.dat").expect("read CTFS calls.dat");
    let offsets = reader.read_file("calls.off").expect("read CTFS calls.off");
    call_record_slices(&calls, &offsets)
        .into_iter()
        .map(|record| {
            decode_first_value_record(record).unwrap_or_else(|| {
                panic!("call record should contain a CBOR return value: {record:02x?}")
            })
        })
        .map(|value| trace_value_text(&value))
        .collect()
}

fn call_record_slices<'a>(calls: &'a [u8], offsets: &[u8]) -> Vec<&'a [u8]> {
    let mut parsed_offsets = offsets
        .chunks_exact(8)
        .map(|chunk| {
            let mut bytes = [0_u8; 8];
            bytes.copy_from_slice(chunk);
            u64::from_le_bytes(bytes) as usize
        })
        .collect::<Vec<_>>();
    parsed_offsets.retain(|offset| *offset <= calls.len());
    parsed_offsets
        .windows(2)
        .filter_map(|window| calls.get(window[0]..window[1]))
        .filter(|record| !record.is_empty())
        .collect()
}

fn decode_first_value_record(record: &[u8]) -> Option<ValueRecord> {
    (0..record.len()).find_map(|offset| {
        cbor4ii::serde::from_reader::<ValueRecord, _>(Cursor::new(&record[offset..])).ok()
    })
}

fn trace_value_text(value: &ValueRecord) -> String {
    match value {
        ValueRecord::Int { i, .. } => i.to_string(),
        ValueRecord::Raw { r, .. } => r.clone(),
        ValueRecord::None { .. } => "None".to_string(),
        other => serde_json::to_string(other).expect("serialize trace value"),
    }
}

fn reader_function_names(reader: &NimTraceReaderHandle) -> Vec<String> {
    (0..reader.function_count())
        .filter_map(|id| reader.function(id).ok())
        .map(|raw| normalize_function_json(&raw))
        .collect()
}

fn reader_call_function_names(reader: &NimTraceReaderHandle) -> Vec<String> {
    (0..reader.call_count())
        .filter_map(|key| reader.call_json(key).ok())
        .filter_map(|raw| {
            let json = serde_json::from_str::<Value>(&raw).ok()?;
            if let Some(name) = find_string_for_keys(&json, &["function", "function_name", "name"])
            {
                return Some(name);
            }
            let function_id =
                find_u64_for_keys(&json, &["function_id", "functionId", "functionID"])?;
            reader
                .function(function_id)
                .ok()
                .map(|function| normalize_function_json(&function))
        })
        .collect()
}

fn normalize_function_json(raw: &str) -> String {
    let Ok(json) = serde_json::from_str::<Value>(raw) else {
        return raw.to_string();
    };
    if let Some(name) = json.as_str() {
        return name.to_string();
    }
    find_string_for_keys(&json, &["name", "function", "function_name"])
        .unwrap_or_else(|| raw.to_string())
}

fn find_string_for_keys(value: &Value, keys: &[&str]) -> Option<String> {
    match value {
        Value::Object(map) => {
            for key in keys {
                if let Some(text) = map.get(*key).and_then(Value::as_str) {
                    return Some(text.to_string());
                }
            }
            map.values()
                .find_map(|nested| find_string_for_keys(nested, keys))
        }
        Value::Array(values) => values
            .iter()
            .find_map(|nested| find_string_for_keys(nested, keys)),
        _ => None,
    }
}

fn find_u64_for_keys(value: &Value, keys: &[&str]) -> Option<u64> {
    match value {
        Value::Object(map) => {
            for key in keys {
                if let Some(id) = map.get(*key).and_then(Value::as_u64) {
                    return Some(id);
                }
            }
            map.values()
                .find_map(|nested| find_u64_for_keys(nested, keys))
        }
        Value::Array(values) => values
            .iter()
            .find_map(|nested| find_u64_for_keys(nested, keys)),
        _ => None,
    }
}

fn decode_reader_event_content(event_json: &str) -> String {
    let Ok(value) = serde_json::from_str::<Value>(event_json) else {
        return event_json.to_string();
    };
    let Some(bytes) = value.get("data").and_then(Value::as_array) else {
        return event_json.to_string();
    };
    let bytes = bytes
        .iter()
        .filter_map(|byte| byte.as_u64().and_then(|value| u8::try_from(value).ok()))
        .collect::<Vec<_>>();
    String::from_utf8(bytes).unwrap_or_else(|_| event_json.to_string())
}

fn sidecar_message_events(events: &[Value]) -> Vec<&Value> {
    events
        .iter()
        .filter(|event| {
            matches!(
                event.get("event").and_then(Value::as_str),
                Some("message_send" | "message_receive")
            )
        })
        .collect()
}

fn find_message_event<'a>(messages: &'a [&'a Value], direction: &str, tag: &str) -> &'a Value {
    messages
        .iter()
        .copied()
        .find(|event| {
            event["direction"] == direction
                && event["tag"] == tag
                && event["schema"] == "codetracer.beam.message.v1"
        })
        .unwrap_or_else(|| {
            panic!("missing {direction} message with tag {tag}; messages={messages:#?}")
        })
}

fn assert_reader_trace_log_contains(out_dir: &Path, trace_file: &str, tags: &[&str]) {
    let reader = open_named_trace(out_dir, trace_file);
    let event_payloads = (0..reader.event_count())
        .map(|index| {
            decode_reader_event_content(&reader.event_json(index).expect("read event json"))
        })
        .collect::<Vec<_>>();

    for tag in tags {
        assert!(
            event_payloads.iter().any(|payload| {
                payload.contains("codetracer.beam.message.v1")
                    && payload.contains(&format!(r#""tag":"{tag}""#))
            }),
            "reader should expose TraceLogEvent payload for tag {tag}: {event_payloads:#?}"
        );
    }
}

fn sidecar_thread_ids(events: &[Value], event_name: &str) -> Vec<u64> {
    events
        .iter()
        .filter(|event| event["event"] == event_name)
        .filter_map(|event| event["thread_id"].as_u64())
        .collect()
}

fn assert_reader_thread_event(out_dir: &Path, trace_file: &str, kind: &str, thread_id: u64) {
    let reader = open_named_trace(out_dir, trace_file);
    let expected_kind = format!(r#""kind":"{kind}""#);
    let expected_thread = format!(r#""thread_id":{thread_id}"#);
    let step_jsons = (0..reader.step_count())
        .map(|index| reader.step_json(index).expect("read step json"))
        .collect::<Vec<_>>();
    assert!(
        step_jsons
            .iter()
            .any(|json| json.contains(&expected_kind) && json.contains(&expected_thread)),
        "missing reader thread event {kind} for thread {thread_id}: {step_jsons:#?}"
    );
}

#[test]
fn e2e_runtime_session_records_real_elixir_process() {
    let tmp = temp_dir("runtime-elixir");
    let out_dir = tmp.join("trace");
    let elixir_fixture = repo_root().join("test-programs/elixir/canonical_flow");
    let mix_build_root = tmp.join("mix-build");
    compile_elixir_fixture(&elixir_fixture, &mix_build_root);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "mix",
            "run",
            "--no-compile",
            "-e",
            "CanonicalFlow.main()",
        ])
        .current_dir(&elixir_fixture)
        .env("MIX_ENV", "test")
        .env("MIX_BUILD_ROOT", &mix_build_root)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Elixir fixture under runtime session");

    assert_eq!(output.status.code(), Some(0), "{}", output_text(&output));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "94\n");
    assert_runtime_session_trace(
        &out_dir,
        "mix.ct",
        "Mix M4 injection",
        "lib/canonical_flow.ex",
    );
}

#[test]
fn e2e_runtime_records_canonical_call_return_sequence() {
    let recorded = record_elixir_expression("m5-call-return", "CanonicalFlow.main()");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(String::from_utf8_lossy(&recorded.output.stdout), "94\n");

    let events = runtime_sidecar_events(&recorded.out_dir);
    let observed = events
        .iter()
        .filter_map(|event| match event["event"].as_str()? {
            "call" => Some(format!(
                "call {}.{}/{}",
                event["module"].as_str()?,
                event["function"].as_str()?,
                event["arity"].as_u64()?
            )),
            "return_from" => Some(format!(
                "return {}.{}/{}={}",
                event["module"].as_str()?,
                event["function"].as_str()?,
                event["arity"].as_u64()?,
                event["return_value"]
            )),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        observed,
        vec![
            "call Elixir.CanonicalFlow.main/0",
            "call Elixir.CanonicalFlow.compute/0",
            "return Elixir.CanonicalFlow.compute/0=94",
            "return Elixir.CanonicalFlow.main/0=94",
        ]
    );

    let reader = open_mix_trace(&recorded.out_dir);
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names.iter().any(|name| name == "CanonicalFlow.main/0")
            && call_names
                .iter()
                .any(|name| name == "CanonicalFlow.compute/0"),
        "reader should expose canonical call records after sidecar sequence validation: {call_names:#?}"
    );

    assert_eq!(
        raw_ctfs_call_return_values(&recorded.out_dir),
        vec!["94", "94"],
        "raw CTFS calls.dat should contain return values for compute/0 and main/0"
    );
}

#[test]
fn e2e_runtime_records_real_exception_fixture() {
    let recorded = record_elixir_expression("m5-exception", "CanonicalFlow.raises()");
    assert!(
        !recorded.output.status.success(),
        "exception fixture should propagate target failure\n{}",
        output_text(&recorded.output)
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "exception_from"
                && event["module"] == "Elixir.CanonicalFlow"
                && event["function"] == "raises"
                && event["arity"] == 0
                && event["class"] == "error"
                && event["reason_repr"]
                    .as_str()
                    .is_some_and(|reason| reason.contains("m5 fixture exception"))
        }),
        "sidecar should contain real exception_from metadata: {events:#?}"
    );

    let reader = open_mix_trace(&recorded.out_dir);
    let event_jsons = (0..reader.event_count())
        .map(|index| {
            decode_reader_event_content(&reader.event_json(index).expect("read event json"))
        })
        .collect::<Vec<_>>();
    assert!(
        event_jsons.iter().any(|event| {
            event.contains("codetracer.elixir.exception_from.v1")
                && event.contains("Elixir.CanonicalFlow")
                && event.contains("m5 fixture exception")
        }),
        "reader should expose exception_from as Error event with schema metadata: {event_jsons:#?}"
    );
}

#[test]
fn e2e_runtime_records_elixir_task_messages() {
    let recorded =
        record_elixir_fixture_expression("m6-elixir-task", "task_messages", "TaskMessages.main()");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "task-ok\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    let messages = sidecar_message_events(&events);
    let task_go_send = find_message_event(&messages, "send", "task_go");
    let task_go_receive = find_message_event(&messages, "receive", "task_go");
    let task_ready_send = find_message_event(&messages, "send", "task_ready");
    let task_ready_receive = find_message_event(&messages, "receive", "task_ready");
    let task_ack_send = find_message_event(&messages, "send", "task_ack");
    let task_ack_receive = find_message_event(&messages, "receive", "task_ack");

    assert_eq!(task_go_send["sender_thread_id"], 1);
    assert_eq!(task_go_send["sender_pid"], task_go_receive["sender_pid"]);
    assert_eq!(
        task_go_send["recipient_pid"],
        task_go_receive["recipient_pid"]
    );
    assert_eq!(
        task_go_send["recipient_thread_id"],
        task_go_receive["recipient_thread_id"]
    );
    assert_eq!(
        task_ready_send["sender_thread_id"],
        task_go_send["recipient_thread_id"]
    );
    assert_eq!(task_ready_send["recipient_thread_id"], 1);
    assert_eq!(
        task_ready_send["sender_pid"],
        task_ready_receive["sender_pid"]
    );
    assert_eq!(
        task_ack_send["recipient_thread_id"],
        task_go_send["recipient_thread_id"]
    );
    assert_eq!(
        task_ack_send["sender_thread_id"],
        task_ack_receive["sender_thread_id"]
    );
    assert_eq!(task_ack_send["message_format"], "erlang_external_text");
    assert_eq!(task_ack_send["message_truncated"], false);

    let task_thread_id = task_go_send["recipient_thread_id"]
        .as_u64()
        .expect("task recipient thread id");
    assert!(
        sidecar_thread_ids(&events, "thread_start").contains(&task_thread_id),
        "Task process should have a stable ThreadStart: {events:#?}"
    );
    assert!(
        sidecar_thread_ids(&events, "thread_exit").contains(&task_thread_id),
        "Task process should have a ThreadExit: {events:#?}"
    );
    assert!(
        sidecar_thread_ids(&events, "thread_switch").contains(&task_thread_id)
            && sidecar_thread_ids(&events, "thread_switch").contains(&1),
        "message flow should switch between root and task threads: {events:#?}"
    );

    assert_reader_thread_event(&recorded.out_dir, "mix.ct", "thread_start", task_thread_id);
    assert_reader_thread_event(&recorded.out_dir, "mix.ct", "thread_switch", task_thread_id);
    assert_reader_thread_event(&recorded.out_dir, "mix.ct", "thread_exit", task_thread_id);
    assert_reader_trace_log_contains(
        &recorded.out_dir,
        "mix.ct",
        &["task_go", "task_ready", "task_ack"],
    );
}

#[test]
fn e2e_runtime_records_erlang_spawn_messages() {
    let recorded = record_erlang_spawn_function("m6-erlang-spawn", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "spawn-ok\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    let messages = sidecar_message_events(&events);
    let ping_send = find_message_event(&messages, "send", "spawn_ping");
    let ping_receive = find_message_event(&messages, "receive", "spawn_ping");
    let pong_send = find_message_event(&messages, "send", "spawn_pong");
    let pong_receive = find_message_event(&messages, "receive", "spawn_pong");

    assert_eq!(ping_send["sender_thread_id"], 1);
    assert_eq!(ping_send["sender_pid"], ping_receive["sender_pid"]);
    assert_eq!(ping_send["recipient_pid"], ping_receive["recipient_pid"]);
    assert_eq!(
        ping_send["recipient_thread_id"],
        ping_receive["recipient_thread_id"]
    );
    assert_eq!(
        pong_send["sender_thread_id"],
        ping_send["recipient_thread_id"]
    );
    assert_eq!(pong_send["recipient_thread_id"], 1);
    assert_eq!(pong_send["sender_pid"], pong_receive["sender_pid"]);
    assert_eq!(pong_send["recipient_pid"], pong_receive["recipient_pid"]);

    let child_thread_id = ping_send["recipient_thread_id"]
        .as_u64()
        .expect("spawn child recipient thread id");
    assert!(
        sidecar_thread_ids(&events, "thread_start").contains(&child_thread_id),
        "spawned Erlang process should have ThreadStart: {events:#?}"
    );
    assert!(
        sidecar_thread_ids(&events, "thread_exit").contains(&child_thread_id),
        "spawned Erlang process should have ThreadExit: {events:#?}"
    );
    assert!(
        sidecar_thread_ids(&events, "thread_switch").contains(&child_thread_id),
        "spawned Erlang process should receive a ThreadSwitch: {events:#?}"
    );

    assert_reader_thread_event(&recorded.out_dir, "erl.ct", "thread_start", child_thread_id);
    assert_reader_thread_event(
        &recorded.out_dir,
        "erl.ct",
        "thread_switch",
        child_thread_id,
    );
    assert_reader_thread_event(&recorded.out_dir, "erl.ct", "thread_exit", child_thread_id);
    assert_reader_trace_log_contains(&recorded.out_dir, "erl.ct", &["spawn_ping", "spawn_pong"]);
}

#[test]
fn e2e_runtime_trace_delivered_flush_barrier() {
    let recorded = record_erlang_spawn_function("m6-flush-barrier", "flood");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "flush-ok\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "trace_delivered" && event["delivery_target"] == "all"
        }),
        "runtime sidecar should contain erlang:trace_delivered(all) barrier: {events:#?}"
    );

    let messages = sidecar_message_events(&events);
    let flush_receives = messages
        .iter()
        .filter(|event| event["direction"] == "receive" && event["tag"] == "flush_ping")
        .collect::<Vec<_>>();
    assert_eq!(
        flush_receives.len(),
        64,
        "every deterministic flood message should be received before final flush"
    );
    for index in 1..=64 {
        let expected_repr = format!("{{flush_ping,{index}}}");
        assert!(
            flush_receives
                .iter()
                .any(|event| event["message_repr"] == expected_repr),
            "missing received flood message {expected_repr}: {flush_receives:#?}"
        );
    }

    assert_reader_trace_log_contains(&recorded.out_dir, "erl.ct", &["flush_ping", "flush_done"]);
}

#[test]
fn e2e_manifest_loaded_by_runtime_session() {
    let recorded = record_elixir_expression("m7-manifest-loaded", "CanonicalFlow.identity(42)");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let canonical_manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.CanonicalFlow")
        .unwrap_or_else(|| panic!("missing CanonicalFlow manifest: {manifests:#?}"));
    assert_eq!(
        canonical_manifest["schema"],
        "codetracer.beam.module-manifest.v1"
    );
    assert_eq!(canonical_manifest["encoding"], "json");
    assert!(
        canonical_manifest["functions"]
            .as_array()
            .is_some_and(|functions| functions.iter().any(|function| {
                function["key"] == "Elixir.CanonicalFlow.identity/1"
                    && function["location_id"].as_u64().is_some()
            })),
        "manifest should define identity/1 function keys and location IDs: {canonical_manifest:#?}"
    );
    assert!(
        canonical_manifest["variable_slot_templates"]
            .as_array()
            .is_some_and(|slots| slots.iter().any(|slot| {
                slot["function_key"] == "Elixir.CanonicalFlow.identity/1" && slot["name"] == "_arg0"
            })),
        "manifest should define runtime argument slot templates: {canonical_manifest:#?}"
    );

    let meta = trace_meta(&recorded.out_dir);
    assert!(
        meta["manifests"].as_array().is_some_and(|manifests| {
            manifests.iter().any(|manifest| {
                manifest["module"] == "Elixir.CanonicalFlow"
                    && manifest["trace_copy_path"]
                        == "recorder_metadata/manifests/Elixir.CanonicalFlow.manifest.json"
            })
        }),
        "trace metadata should expose manifest bundle paths relative to recorder metadata: {meta:#?}"
    );
    assert!(
        recorded
            .out_dir
            .join("recorder_metadata/manifests/Elixir.CanonicalFlow.manifest.json")
            .is_file(),
        "trace bundle should contain the CanonicalFlow manifest artifact"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    let manifest_loaded = events
        .iter()
        .find(|event| event["event"] == "manifest_loaded")
        .unwrap_or_else(|| panic!("missing runtime manifest_loaded event: {events:#?}"));
    assert_eq!(manifest_loaded["encoding"], "json");
    assert!(
        manifest_loaded["manifest_count"]
            .as_u64()
            .unwrap_or_default()
            >= 1,
        "runtime should load real manifest files: {manifest_loaded:#?}"
    );
    assert!(
        manifest_loaded["manifest_paths"]
            .as_array()
            .is_some_and(|paths| paths.iter().all(|path| {
                path.as_str().is_some_and(|path| {
                    Path::new(path).is_absolute()
                        && path.ends_with(".manifest.json")
                        && Path::new(path).is_file()
                })
            })),
        "runtime should load manifests from real absolute filesystem paths: {manifest_loaded:#?}"
    );
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "Elixir.CanonicalFlow"
                && event["function"] == "identity"
                && event["manifest_id"] == "beam-manifest-v1:Elixir.CanonicalFlow"
                && event["function_key"] == "Elixir.CanonicalFlow.identity/1"
                && event["location_id"].as_u64().is_some()
                && event["clause_id"].as_u64().is_some()
        }),
        "runtime call events should resolve through manifest IDs: {events:#?}"
    );
}

#[test]
fn e2e_source_location_resolution_real_files() {
    let elixir = record_elixir_expression("m7-source-elixir", "CanonicalFlow.compute()");
    assert_eq!(
        elixir.output.status.code(),
        Some(0),
        "{}",
        output_text(&elixir.output)
    );
    let elixir_meta = trace_meta(&elixir.out_dir);
    assert_eq!(
        elixir_meta["metadata_contract"]["source_location_resolver_order"],
        serde_json::json!([
            "source_map",
            "erl_anno",
            "module_file_fallback",
            "unknown_generated_fallback"
        ])
    );
    assert!(
        elixir_meta["sources"].as_array().is_some_and(|sources| {
            sources.iter().any(|source| {
                source["build_path"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("lib/canonical_flow.ex"))
                    && source["trace_copy_path"] == "files/lib/canonical_flow.ex"
            })
        }),
        "Elixir source should be normalized to build and trace-copy paths: {elixir_meta:#?}"
    );
    assert!(
        elixir.out_dir.join("files/lib/canonical_flow.ex").is_file(),
        "trace bundle should contain project-relative Elixir source copy"
    );

    let erlang = {
        let tmp = temp_dir("m7-source-erlang");
        let out_dir = tmp.join("trace");
        let fixture_dir = repo_root().join("test-programs/erlang/canonical_flow");
        let ebin_dir = tmp.join("erlang-ebin");
        compile_erlang_fixture(&ebin_dir);
        let output = clean_recorder_command()
            .args([
                "record",
                "--out-dir",
                out_dir.to_str().unwrap(),
                "--",
                "erl",
                "-noshell",
                "-pa",
                ebin_dir.to_str().unwrap(),
                "-s",
                "canonical_flow",
                "main",
                "-s",
                "init",
                "stop",
            ])
            .current_dir(&fixture_dir)
            .env("TMPDIR", tmp.to_str().unwrap())
            .output()
            .expect("run Erlang fixture under runtime session");
        RecordedTrace { out_dir, output }
    };
    assert_eq!(
        erlang.output.status.code(),
        Some(0),
        "{}",
        output_text(&erlang.output)
    );
    assert!(
        erlang
            .out_dir
            .join("files/src/canonical_flow.erl")
            .is_file(),
        "trace bundle should contain project-relative Erlang source copy"
    );

    let reader = open_named_trace(&erlang.out_dir, "erl.ct");
    let function_names = reader_function_names(&reader);
    assert!(
        function_names
            .iter()
            .any(|name| name == "canonical_flow:main/0"),
        "reader should expose real Erlang source metadata through function records: {function_names:#?}"
    );
}

#[test]
fn e2e_source_map_sparse_override_real_trace() {
    let recorded = record_erlang_generated_source_map_function("m7-source-map", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "mapped-ok:42\n"
    );

    let meta = trace_meta(&recorded.out_dir);
    assert!(
        meta["source_maps"].as_array().is_some_and(|maps| {
            maps.iter().any(|map| {
                map["generated_build_path"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("src/generated_bridge.erl"))
                    && map["original_build_path"]
                        .as_str()
                        .is_some_and(|path| path.ends_with("lib/original_generated.ex"))
                    && map["trace_copy_path"]
                        == "recorder_metadata/source_maps/001-src_generated_bridge.erl.json"
            })
        }),
        "trace metadata should list copied sparse source-map artifact: {meta:#?}"
    );
    assert!(
        recorded
            .out_dir
            .join("recorder_metadata/source_maps/001-src_generated_bridge.erl.json")
            .is_file(),
        "trace bundle should contain copied sparse source-map artifact"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let generated_manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "generated_bridge")
        .unwrap_or_else(|| panic!("missing generated_bridge manifest: {manifests:#?}"));
    assert!(
        generated_manifest["source_maps"]
            .as_array()
            .is_some_and(|paths| paths.iter().any(|path| {
                path == "recorder_metadata/source_maps/001-src_generated_bridge.erl.json"
            })),
        "module manifest should reference bundle-relative source-map artifacts: {generated_manifest:#?}"
    );
    assert!(
        generated_manifest["locations"]
            .as_array()
            .is_some_and(|locations| locations.iter().any(|location| {
                location["resolution"] == "source_map"
                    && location["trace_copy_path"] == "files/lib/original_generated.ex"
                    && location["build_path"]
                        .as_str()
                        .is_some_and(|path| path.ends_with("lib/original_generated.ex"))
            })),
        "generated Erlang manifest locations should prefer sparse source-map overrides: {generated_manifest:#?}"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "generated_bridge"
                && event["source_location"]["resolution"] == "source_map"
                && event["source_location"]["trace_copy_path"] == "files/lib/original_generated.ex"
        }),
        "runtime call events should carry source-map-resolved source locations: {events:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    assert!(
        paths
            .iter()
            .any(|path| path.ends_with("lib/original_generated.ex")),
        "reader/raw CTFS-visible paths should include original source from source-map resolution: {paths:#?}"
    );
}

#[test]
fn m8_e2e_instrumented_erlang_steps_match_golden() {
    let recorded = record_erlang_canonical_function("m8-erlang-steps", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(String::from_utf8_lossy(&recorded.output.stdout), "94\n");

    let observed = sidecar_step_locations(&recorded.out_dir)
        .into_iter()
        .filter(|(path, _, _)| path == "files/src/canonical_flow.erl")
        .map(|(_, line, resolution)| (line, resolution))
        .collect::<Vec<_>>();
    let expected = [14, 5, 6, 7, 8, 9, 10, 11, 15, 16, 17]
        .into_iter()
        .map(|line| (line, "erl_anno".to_string()))
        .collect::<Vec<_>>();
    assert_eq!(
        observed, expected,
        "instrumented Erlang step sequence should match first-principles executable source lines"
    );

    let step_location_files = step_location_jsons(&recorded.out_dir);
    let canonical_steps = step_location_files
        .iter()
        .find(|locations| locations["module"] == "canonical_flow")
        .unwrap_or_else(|| {
            panic!("missing canonical_flow step locations: {step_location_files:#?}")
        });
    assert!(
        canonical_steps["locations"].as_array().is_some_and(|locations| {
            locations.iter().all(|location| {
                location["file"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("src/canonical_flow.erl"))
                    && location["column"].as_i64().is_some()
                    && location["generated"] == false
            })
        }),
        "raw step-location metadata should preserve erl_anno file/column/generated flags: {canonical_steps:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    assert!(
        reader.step_count() >= expected.len() as u64,
        "real CTFS reader should expose at least the instrumented source steps"
    );

    let dump = transformed_dump_text(&recorded.out_dir, "src_canonical_flow.erl.transformed.erl");
    assert!(
        dump.starts_with(
            "%% codetracer transformed forms dump format: erl_pp:form/1 pretty-printed Erlang source"
        ) && dump.contains("codetracer_erlang_runtime:step("),
        "transformed forms dump should use the reviewed pretty-printed Erlang format: {dump}"
    );
    let meta = trace_meta(&recorded.out_dir);
    assert!(
        meta["transformed_form_dumps"]
            .as_array()
            .is_some_and(|dumps| {
                dumps.iter().any(|dump| {
                    dump["module"] == "canonical_flow"
                        && dump["format"] == "erl_pp:form/1 pretty-printed Erlang source"
                        && dump["trace_copy_path"].as_str().is_some_and(|path| {
                            path.ends_with("src_canonical_flow.erl.transformed.erl")
                        })
                })
            }),
        "trace metadata should expose transformed-form debug dumps: {meta:#?}"
    );
}

#[test]
fn m8_e2e_instrumented_elixir_generated_steps_match_original_source() {
    let recorded = record_erlang_generated_source_map_function("m8-elixir-generated-steps", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "mapped-ok:42\n"
    );

    let observed = sidecar_step_locations(&recorded.out_dir)
        .into_iter()
        .filter(|(path, _, resolution)| {
            path == "files/lib/original_generated.ex" && resolution == "source_map"
        })
        .map(|(_, line, _)| line)
        .collect::<Vec<_>>();
    assert_eq!(
        observed,
        vec![11, 5, 6, 7, 12, 13],
        "generated Erlang steps should resolve to original Elixir source-map lines"
    );

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    assert!(
        paths
            .iter()
            .any(|path| path.ends_with("lib/original_generated.ex")),
        "CTFS paths should include original Elixir source for generated Erlang steps: {paths:#?}"
    );
}

#[test]
fn m8_e2e_branch_body_entries_for_control_flow_forms() {
    let recorded = record_erlang_branch_function("m8-branch-forms", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "branch-ok\n"
    );

    let observed = sidecar_step_locations(&recorded.out_dir)
        .into_iter()
        .filter(|(path, _, resolution)| {
            path == "files/src/branch_forms.erl" && resolution == "erl_anno"
        })
        .map(|(_, line, _)| line)
        .collect::<Vec<_>>();
    assert_ordered_subsequence(&observed, &[5, 7, 13, 15, 22, 24, 30, 31, 34, 39]);

    let dump = transformed_dump_text(&recorded.out_dir, "src_branch_forms.erl.transformed.erl");
    for branch_entry in [
        "1 ->\n            codetracer_erlang_runtime:step(",
        "Value > 0 ->\n            codetracer_erlang_runtime:step(",
        "{branch_msg, N} ->\n            codetracer_erlang_runtime:step(",
        "try\n        codetracer_erlang_runtime:step(",
        "Quotient ->\n            codetracer_erlang_runtime:step(",
        "after\n        codetracer_erlang_runtime:step(",
    ] {
        assert!(
            dump.contains(branch_entry),
            "transformed forms should contain branch/body entry marker {branch_entry:?}: {dump}"
        );
    }
}

#[test]
fn m8_e2e_tail_recursion_semantics_preserved() {
    let tmp = temp_dir("m8-tail-original");
    let original_ebin = tmp.join("original-ebin");
    compile_erlang_tail_fixture(&original_ebin);
    let original = Command::new("erl")
        .args([
            "-noshell",
            "-pa",
            original_ebin.to_str().unwrap(),
            "-s",
            "tail_recursion",
            "main",
            "-s",
            "init",
            "stop",
        ])
        .output()
        .expect("run original tail recursion fixture");
    assert_success(&original, "original tail recursion fixture");
    assert_eq!(String::from_utf8_lossy(&original.stdout), "5000\n");

    let recorded = record_erlang_tail_function("m8-tail-instrumented", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(String::from_utf8_lossy(&recorded.output.stdout), "5000\n");

    let dump = transformed_dump_text(&recorded.out_dir, "src_tail_recursion.erl.transformed.erl");
    assert!(
        dump.contains("count_down(N - 1, Acc + 1)."),
        "tail-recursive call should remain the final expression in its clause: {dump}"
    );
    assert!(
        !dump.contains("case count_down(N - 1, Acc + 1)")
            && !dump.contains("begin\n        count_down(N - 1, Acc + 1),"),
        "transformed forms must not add post-tail-call wrappers: {dump}"
    );
}

#[test]
fn e2e_runtime_call_trace_reader_roundtrip() {
    let recorded = record_elixir_expression("m5-reader-roundtrip", "CanonicalFlow.identity(42)");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );

    let reader = open_mix_trace(&recorded.out_dir);
    let function_names = reader_function_names(&reader);
    assert!(
        function_names
            .iter()
            .any(|name| name == "CanonicalFlow.identity/1"),
        "reader should expose recorder-interned identity/1 function: {function_names:#?}"
    );

    let call_jsons = (0..reader.call_count())
        .map(|key| reader.call_json(key).expect("read call json"))
        .collect::<Vec<_>>();
    let varnames = (0..reader.varname_count())
        .map(|id| reader.varname(id).expect("read varname"))
        .collect::<Vec<_>>();
    assert!(
        varnames.iter().any(|name| name == "_arg0")
            && call_jsons.iter().any(|call| call.contains("42")),
        "reader should expose generic _arg0 argument with real BEAM value 42: varnames={varnames:#?} calls={call_jsons:#?}"
    );

    assert_eq!(
        raw_ctfs_call_return_values(&recorded.out_dir),
        vec!["42"],
        "raw CTFS calls.dat should contain the identity/1 return value"
    );
}

#[test]
fn e2e_runtime_session_records_real_erlang_process() {
    let tmp = temp_dir("runtime-erlang");
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang/canonical_flow");
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_fixture(&ebin_dir);

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir.to_str().unwrap(),
            "-s",
            "canonical_flow",
            "main",
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Erlang fixture under runtime session");

    assert_eq!(output.status.code(), Some(0), "{}", output_text(&output));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "94\n");
    assert_runtime_session_trace(
        &out_dir,
        "erl.ct",
        "plain erl M4 injection",
        "src/canonical_flow.erl",
    );
}

fn assert_runtime_session_trace(
    out_dir: &Path,
    ct_file_name: &str,
    expected_injection_text: &str,
    expected_source: &str,
) {
    let ct_path = out_dir.join(ct_file_name);
    assert!(
        ct_path.is_file(),
        "expected CTFS trace at {}",
        ct_path.display()
    );

    let reader = NimTraceReaderHandle::open(ct_path.to_str().expect("trace path utf-8"))
        .expect("open runtime CTFS trace through real reader bridge");
    let step_jsons = (0..reader.step_count())
        .map(|index| reader.step_json(index).expect("read step json"))
        .collect::<Vec<_>>();
    assert!(
        step_jsons
            .iter()
            .any(|json| json.contains("\"kind\":\"thread_start\"")
                && json.contains("\"thread_id\":1")),
        "missing root ThreadStart in {step_jsons:#?}"
    );
    assert!(
        step_jsons
            .iter()
            .any(|json| json.contains("\"kind\":\"thread_switch\"")
                && json.contains("\"thread_id\":1")),
        "missing initial root ThreadSwitch in {step_jsons:#?}"
    );
    assert!(
        step_jsons
            .iter()
            .any(|json| json.contains("\"kind\":\"thread_exit\"")
                && json.contains("\"thread_id\":1")),
        "missing root ThreadExit in {step_jsons:#?}"
    );

    let copied_source = out_dir.join("source_map").join(expected_source);
    assert!(
        copied_source.is_file(),
        "expected copied source at {}",
        copied_source.display()
    );

    let trace_meta_path = out_dir.join("trace_meta.json");
    let trace_meta_text = fs::read_to_string(&trace_meta_path)
        .unwrap_or_else(|error| panic!("read {}: {error}", trace_meta_path.display()));
    let trace_meta: Value = serde_json::from_str(&trace_meta_text).expect("trace_meta.json");
    assert_eq!(trace_meta["runtime_session"]["mode"], "beam");
    assert_eq!(trace_meta["runtime_session"]["delivered"], true);
    assert_eq!(trace_meta["runtime_session"]["root_thread_id"], 1);
    assert!(
        trace_meta["runtime_session"]["root_pid"].as_str().is_some(),
        "root BEAM pid should be recorded in metadata: {trace_meta}"
    );
    assert!(
        trace_meta["runtime_session"]["injection_decision"]
            .as_str()
            .unwrap_or_default()
            .contains(expected_injection_text),
        "unexpected injection decision: {}",
        trace_meta["runtime_session"]["injection_decision"]
    );
    assert!(
        trace_meta["sources"].as_array().is_some_and(|sources| {
            sources.iter().any(|source| {
                source["bundle_path"]
                    .as_str()
                    .is_some_and(|path| path.ends_with(expected_source))
            })
        }),
        "trace metadata should list copied source {expected_source}: {trace_meta}"
    );

    let sidecar_path = out_dir.join("runtime_session.jsonl");
    let sidecar = fs::read_to_string(&sidecar_path)
        .unwrap_or_else(|error| panic!("read {}: {error}", sidecar_path.display()));
    assert!(
        sidecar.contains(r#""event":"trace_delivered""#)
            && sidecar.contains(r#""delivery_target":"all""#)
            && sidecar.contains("\"delivery_ref\":\"#Ref<"),
        "runtime sidecar should prove erlang:trace_delivered(all) completed: {sidecar}"
    );
}

#[test]
fn e2e_cli_records_disabled_target_execution() {
    let tmp = temp_dir("disabled");
    let elixir_fixture = repo_root().join("test-programs/elixir/canonical_flow");
    let mix_build_root = tmp.join("mix-build");
    compile_elixir_fixture(&elixir_fixture, &mix_build_root);

    let mix_output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            tmp.join("disabled-mix-trace").to_str().unwrap(),
            "--",
            "mix",
            "run",
            "--no-compile",
            "-e",
            "CanonicalFlow.main()",
        ])
        .current_dir(&elixir_fixture)
        .env("MIX_ENV", "test")
        .env("MIX_BUILD_ROOT", &mix_build_root)
        .env("CODETRACER_ELIXIR_RECORDER_DISABLED", "true")
        .output()
        .expect("run disabled mix target");
    assert_eq!(
        mix_output.status.code(),
        Some(0),
        "{}",
        output_text(&mix_output)
    );
    assert_eq!(String::from_utf8_lossy(&mix_output.stdout), "94\n");

    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_fixture(&ebin_dir);
    let erlang_output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            tmp.join("disabled-erlang-trace").to_str().unwrap(),
            "--",
            "erl",
            "-noshell",
            "-pa",
            ebin_dir.to_str().unwrap(),
            "-s",
            "canonical_flow",
            "main",
            "-s",
            "init",
            "stop",
        ])
        .env("CODETRACER_ELIXIR_RECORDER_DISABLED", "1")
        .output()
        .expect("run disabled erlang target");
    assert_eq!(
        erlang_output.status.code(),
        Some(0),
        "{}",
        output_text(&erlang_output)
    );
    assert_eq!(String::from_utf8_lossy(&erlang_output.stdout), "94\n");

    let shell_output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            tmp.join("disabled-shell-trace").to_str().unwrap(),
            "--",
        ])
        .args(["sh", "-c", "printf shell-target; exit 17"])
        .env("CODETRACER_ELIXIR_RECORDER_DISABLED", "true")
        .output()
        .expect("run disabled shell target");
    assert_eq!(
        shell_output.status.code(),
        Some(17),
        "{}",
        output_text(&shell_output)
    );
    assert_eq!(
        String::from_utf8_lossy(&shell_output.stdout),
        "shell-target"
    );
}

#[test]
fn e2e_cli_writes_trace_metadata_with_real_writer() {
    let out_dir = temp_dir("metadata");
    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--",
            "sh",
            "-c",
            "printf recorded-target",
        ])
        .output()
        .expect("run recording target");

    assert_eq!(output.status.code(), Some(0), "{}", output_text(&output));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "recorded-target");

    let ct_path = out_dir.join("sh.ct");
    assert!(
        ct_path.is_file(),
        "expected CTFS trace at {}",
        ct_path.display()
    );

    let reader = NimTraceReaderHandle::open(ct_path.to_str().expect("trace path utf-8"))
        .expect("open CTFS trace through real reader bridge");
    assert_eq!(reader.program(), "sh");
    assert!(reader.path_count() >= 1);
    assert!(reader.step_count() >= 1);
    assert!(reader.event_count() >= 1);

    let trace_meta_path = out_dir.join("trace_meta.json");
    let trace_meta_text = fs::read_to_string(&trace_meta_path)
        .unwrap_or_else(|error| panic!("read {}: {error}", trace_meta_path.display()));
    let trace_meta: Value = serde_json::from_str(&trace_meta_text).expect("trace_meta.json");
    assert_eq!(trace_meta["language"], "elixir");
    assert_eq!(trace_meta["recorder"], "codetracer-elixir-recorder");
    assert_eq!(trace_meta["format"], "ctfs");
    assert_eq!(trace_meta["target"]["exit_code"], 0);
    assert_eq!(trace_meta["artifacts"]["ctfs"], "sh.ct");
}

#[test]
fn e2e_cli_honors_env_vars_and_compile_instrument_aliases() {
    for subcommand in ["compile", "instrument"] {
        let tmp = temp_dir(subcommand);
        let env_out_dir = tmp.join("env-out");
        let cli_out_dir = tmp.join("cli-out");

        let output = clean_recorder_command()
            .args([
                subcommand,
                "--out-dir",
                cli_out_dir.to_str().unwrap(),
                "--",
                "sh",
                "-c",
                "printf alias-target",
            ])
            .env("CODETRACER_ELIXIR_RECORDER_OUT_DIR", &env_out_dir)
            .env("CODETRACER_FORMAT", "json")
            .output()
            .unwrap_or_else(|error| panic!("run {subcommand} alias target: {error}"));

        assert_eq!(output.status.code(), Some(0), "{}", output_text(&output));
        assert_eq!(String::from_utf8_lossy(&output.stdout), "alias-target");
        assert!(
            cli_out_dir.join("trace_meta.json").is_file(),
            "--out-dir should override CODETRACER_ELIXIR_RECORDER_OUT_DIR"
        );
        assert!(
            !env_out_dir.join("trace_meta.json").exists(),
            "env out dir should not be used when --out-dir is present"
        );

        let trace_meta_text = fs::read_to_string(cli_out_dir.join("trace_meta.json"))
            .expect("read alias trace_meta.json");
        let trace_meta: Value = serde_json::from_str(&trace_meta_text).expect("alias trace meta");
        assert_eq!(trace_meta["subcommand"], subcommand);
        assert_eq!(trace_meta["format"], "json");
        assert_eq!(trace_meta["target"]["exit_code"], 0);
    }
}

#[test]
fn e2e_cli_structured_errors() {
    let tmp = temp_dir("errors");

    let invalid_out_file = tmp.join("not-a-directory");
    fs::write(&invalid_out_file, b"not a directory").expect("write invalid output file");
    assert_recorder_error(
        clean_recorder_command()
            .args([
                "record",
                "--out-dir",
                invalid_out_file.to_str().unwrap(),
                "--",
                "sh",
                "-c",
                "echo SHOULD_NOT_RUN",
            ])
            .output()
            .expect("run invalid output dir scenario"),
        "invalid_output_dir",
    );

    assert_recorder_error(
        clean_recorder_command()
            .args([
                "record",
                "--out-dir",
                tmp.join("invalid-format").to_str().unwrap(),
                "--format",
                "yaml",
                "--",
                "sh",
                "-c",
                "echo SHOULD_NOT_RUN",
            ])
            .output()
            .expect("run invalid format scenario"),
        "invalid_format",
    );

    assert_recorder_error(
        clean_recorder_command()
            .args([
                "record",
                "--out-dir",
                tmp.join("missing-target").to_str().unwrap(),
                "--",
            ])
            .output()
            .expect("run missing target scenario"),
        "missing_target",
    );

    let read_only_out_dir = tmp.join("read-only");
    fs::create_dir_all(&read_only_out_dir).expect("create read-only output dir");
    let mut permissions = fs::metadata(&read_only_out_dir)
        .expect("read read-only dir metadata")
        .permissions();
    permissions.set_mode(0o555);
    fs::set_permissions(&read_only_out_dir, permissions).expect("chmod read-only output dir");

    let writer_failure = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            read_only_out_dir.to_str().unwrap(),
            "--",
            "sh",
            "-c",
            "echo SHOULD_NOT_RUN",
        ])
        .output()
        .expect("run writer initialization failure scenario");

    let mut restore_permissions = fs::metadata(&read_only_out_dir)
        .expect("read read-only dir metadata after failure")
        .permissions();
    restore_permissions.set_mode(0o755);
    fs::set_permissions(&read_only_out_dir, restore_permissions)
        .expect("restore output dir permissions");

    assert_recorder_error(writer_failure, "writer_initialization_failed");
}

fn assert_recorder_error(output: Output, expected_code: &str) {
    assert_eq!(output.status.code(), Some(1), "{}", output_text(&output));
    let stderr = String::from_utf8_lossy(&output.stderr);
    let diagnostic: Value = serde_json::from_str(stderr.trim())
        .unwrap_or_else(|error| panic!("diagnostic is not JSON: {error}: {stderr}"));
    assert_eq!(diagnostic["type"], "recorder_error");
    assert_eq!(diagnostic["code"], expected_code);
    assert!(diagnostic["message"].as_str().is_some(), "{diagnostic}");
    assert!(
        !String::from_utf8_lossy(&output.stdout).contains("SHOULD_NOT_RUN"),
        "target executed despite recorder error: {}",
        String::from_utf8_lossy(&output.stdout)
    );
}
