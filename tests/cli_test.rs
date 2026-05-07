use std::fs;
use std::io::Cursor;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use codetracer_ctfs::CtfsReader;
use codetracer_trace_types::{
    FullValueRecord, TraceLowLevelEvent, TypeKind, TypeRecord, ValueRecord,
};
use codetracer_trace_writer_nim::NimTraceReaderHandle;
use serde_json::Value;

fn recorder_binary() -> &'static str {
    env!("CARGO_BIN_EXE_codetracer-elixir-recorder")
}

#[test]
fn e2e_elixir_exception_flow_matrix() {
    let recorded = record_mix_task_eval(
        "m13-elixir-exception-flow",
        "exception_flow",
        "ExceptionFlow.main()",
        &[],
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        String::from_utf8_lossy(&recorded.output.stdout).contains("exception-flow-ok:228"),
        "{}",
        output_text(&recorded.output)
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    for (function, arity) in [
        ("main", 0),
        ("rescue_matrix", 1),
        ("throw_matrix", 1),
        ("exit_matrix", 1),
        ("else_after_matrix", 1),
        ("implicit_body_rescue", 1),
        ("reraise_matrix", 1),
        ("raise_argument", 1),
        ("throw_value", 1),
        ("exit_value", 1),
        ("raise_implicit", 1),
        ("raise_reraised", 1),
    ] {
        assert!(
            events.iter().any(|event| {
                event["event"] == "call"
                    && event["module"] == "Elixir.ExceptionFlow"
                    && event["function"] == function
                    && event["arity"] == arity
                    && event["source_location"]["trace_copy_path"]
                        == "files/lib/exception_flow.ex"
                    && event["source_location"]["resolution"] == "source_map"
            }),
            "runtime sidecar should include Elixir.ExceptionFlow.{function}/{arity} with source-map metadata: {events:#?}"
        );
    }
    for (function, class, reason) in [
        ("raise_argument", "error", "bad 3"),
        ("throw_value", "throw", "{thrown,4}"),
        ("exit_value", "exit", "{exit_reason,5}"),
        ("raise_implicit", "error", "implicit 7"),
        ("raise_reraised", "error", "reraised 8"),
    ] {
        assert!(
            events.iter().any(|event| {
                event["event"] == "exception_from"
                    && event["module"] == "Elixir.ExceptionFlow"
                    && event["function"] == function
                    && event["class"] == class
                    && event["reason_repr"]
                        .as_str()
                        .is_some_and(|text| text.contains(reason))
            }),
            "sidecar should expose exception_from for {function}/1 {class}:{reason}: {events:#?}"
        );
    }

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("rescue_score", 10),
        ("stacktrace_score", 13),
        ("throw_score", 20),
        ("exit_score", 30),
        ("else_score", 40),
        ("implicit_score", 50),
        ("reraise_score", 60),
        ("after_score", 5),
        ("final_total", 228),
    ] {
        assert_sidecar_elixir_binding(&binds, name, value);
    }

    let source_maps = source_map_jsons(&recorded.out_dir);
    assert!(
        source_maps.iter().any(|map| {
            map["source_language"] == "elixir"
                && map["original_path"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("lib/exception_flow.ex"))
                && map["mappings"]
                    .as_array()
                    .is_some_and(|mappings| !mappings.is_empty())
        }),
        "source-map artifacts should map generated Erlang forms back to lib/exception_flow.ex: {source_maps:#?}"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.ExceptionFlow")
        .unwrap_or_else(|| panic!("missing ExceptionFlow manifest: {manifests:#?}"));
    assert!(
        manifest["functions"].as_array().is_some_and(|functions| {
            [
                "Elixir.ExceptionFlow.main/0",
                "Elixir.ExceptionFlow.rescue_matrix/1",
                "Elixir.ExceptionFlow.throw_matrix/1",
                "Elixir.ExceptionFlow.exit_matrix/1",
                "Elixir.ExceptionFlow.else_after_matrix/1",
                "Elixir.ExceptionFlow.implicit_body_rescue/1",
                "Elixir.ExceptionFlow.reraise_matrix/1",
            ]
            .into_iter()
            .all(|key| functions.iter().any(|function| function["key"] == key))
        }) && manifest["locations"].as_array().is_some_and(|locations| {
            locations.iter().any(|location| {
                location["trace_copy_path"] == "files/lib/exception_flow.ex"
                    && location["resolution"] == "source_map"
            })
        }),
        "ExceptionFlow manifest should expose functions and .ex source-map locations: {manifest:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "mix.ct");
    assert!(
        reader.step_count() > 0,
        "CTFS reader should expose ExceptionFlow steps"
    );
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    assert!(
        paths
            .iter()
            .any(|path| path.ends_with("lib/exception_flow.ex")),
        "CTFS reader paths should include lib/exception_flow.ex: {paths:#?}"
    );
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name == "ExceptionFlow.raise_argument/1")
            && call_names
                .iter()
                .any(|name| name == "ExceptionFlow.throw_value/1")
            && call_names
                .iter()
                .any(|name| name == "ExceptionFlow.exit_value/1")
            && call_names
                .iter()
                .any(|name| name == "ExceptionFlow.reraise_matrix/1"),
        "CTFS reader should expose exception-flow call records: {call_names:#?}"
    );

    let event_payloads = (0..reader.event_count())
        .map(|index| {
            decode_reader_event_content(&reader.event_json(index).expect("read event json"))
        })
        .collect::<Vec<_>>();
    for reason in ["bad 3", "thrown", "exit_reason", "implicit 7", "reraised 8"] {
        assert!(
            event_payloads.iter().any(|payload| {
                payload.contains("codetracer.elixir.exception_from.v1")
                    && payload.contains("Elixir.ExceptionFlow")
                    && payload.contains(reason)
            }),
            "CTFS reader should expose exception_from event for {reason}: {event_payloads:#?}"
        );
    }
    assert!(
        event_payloads.iter().any(|payload| {
            payload.contains("codetracer.beam.variable-binding.v1")
                && payload.contains("_final_total@")
        }) && event_payloads.iter().any(|payload| {
            payload.contains("codetracer.beam.source-location.v1")
                && payload.contains("Elixir.ExceptionFlow")
        }),
        "CTFS reader should expose TraceLogEvent payloads for variable bindings and source locations: {event_payloads:#?}"
    );

    let pairs = reader_value_pairs(&recorded.out_dir, "mix.ct");
    for (name, value) in [
        ("rescue_score", 10),
        ("stacktrace_score", 13),
        ("throw_score", 20),
        ("exit_score", 30),
        ("else_score", 40),
        ("implicit_score", 50),
        ("reraise_score", 60),
        ("after_score", 5),
        ("final_total", 228),
    ] {
        assert_reader_elixir_value(&pairs, name, value);
    }

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "mix.ct");
    for (name, value) in [
        ("rescue_score", 10),
        ("stacktrace_score", 13),
        ("throw_score", 20),
        ("exit_score", 30),
        ("else_score", 40),
        ("implicit_score", 50),
        ("reraise_score", 60),
        ("after_score", 5),
        ("final_total", 228),
    ] {
        assert_raw_elixir_value(
            &values,
            name,
            &format!("{value} integer"),
            |record| matches!(record, ValueRecord::Int { i, .. } if *i == value),
        );
    }
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
    build_dir: Option<PathBuf>,
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

fn compile_mix_task_ebin(label: &str) -> PathBuf {
    let tmp = temp_dir(label);
    let ebin = tmp.join("codetracer-task-ebin");
    fs::create_dir_all(&ebin).expect("create Mix task ebin");
    let sources = [
        repo_root().join("lib/codetracer_elixir_recorder/elixir_source_map.ex"),
        repo_root().join("lib/mix/tasks/compile.codetracer.ex"),
        repo_root().join("lib/mix/tasks/codetracer.record.ex"),
    ];
    let output = Command::new("elixirc")
        .arg("-o")
        .arg(&ebin)
        .args(sources)
        .output()
        .expect("compile Codetracer Mix tasks");
    assert_success(&output, "compile Codetracer Mix task ebin");
    ebin
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

fn compile_erlang_value_matrix_fixture(ebin_dir: &Path) {
    fs::create_dir_all(ebin_dir).expect("create value_matrix fixture ebin dir");
    let source = repo_root().join("test-programs/erlang/value_matrix/src/value_matrix.erl");
    let compile = Command::new("erlc")
        .arg("+debug_info")
        .arg("-o")
        .arg(ebin_dir)
        .arg(&source)
        .output()
        .expect("run erlc for value_matrix");
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

fn compile_erlang_sources(source_dir: &Path, ebin_dir: &Path) {
    fs::create_dir_all(ebin_dir).expect("create Erlang ebin dir");
    let mut sources = fs::read_dir(source_dir)
        .unwrap_or_else(|error| panic!("read {}: {error}", source_dir.display()))
        .map(|entry| entry.expect("source entry").path())
        .filter(|path| path.extension().and_then(|extension| extension.to_str()) == Some("erl"))
        .collect::<Vec<_>>();
    sources.sort();
    for source in sources {
        let compile = Command::new("erlc")
            .arg("+debug_info")
            .arg("-o")
            .arg(ebin_dir)
            .arg(&source)
            .output()
            .expect("run erlc for standalone fixture");
        assert_success(&compile, &format!("erlc {}", source.display()));
    }
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

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
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

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
}

fn record_mix_task_eval(
    label: &str,
    fixture_name: &str,
    expression: &str,
    extra_args: &[&str],
) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let build_dir = tmp.join("codetracer-build");
    let mix_build_root = tmp.join("mix-build");
    let task_ebin = compile_mix_task_ebin(&format!("{label}-task"));
    let fixture_dir = repo_root().join("test-programs/elixir").join(fixture_name);
    let task_ebin_arg = format!("-pa {}", task_ebin.display());

    let mut args = vec![
        "codetracer.record",
        "--build-dir",
        build_dir.to_str().unwrap(),
        "--out-dir",
        out_dir.to_str().unwrap(),
        "--eval",
        expression,
    ];
    args.extend_from_slice(extra_args);

    let output = Command::new("mix")
        .args(args)
        .current_dir(&fixture_dir)
        .env("MIX_ENV", "test")
        .env("MIX_BUILD_ROOT", &mix_build_root)
        .env("TMPDIR", tmp.to_str().unwrap())
        .env("ERL_FLAGS", &task_ebin_arg)
        .env("ELIXIR_ERL_OPTIONS", &task_ebin_arg)
        .env("CODETRACER_ELIXIR_RECORDER_BIN", recorder_binary())
        .env("CODETRACER_ELIXIR_RECORDER_ROOT", repo_root())
        .output()
        .expect("run mix codetracer.record");

    RecordedTrace {
        out_dir,
        build_dir: Some(build_dir),
        output,
    }
}

fn record_rebar3_profile(
    label: &str,
    fixture_name: &str,
    profile: &str,
    extra_args: &[&str],
) -> RecordedTrace {
    static REBAR3_FIXTURE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    let _guard = REBAR3_FIXTURE_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .expect("lock Rebar3 fixture");
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let build_dir = tmp.join("codetracer-build");
    let fixture_dir = repo_root().join("test-programs/erlang").join(fixture_name);
    let _ = fs::remove_dir_all(fixture_dir.join("_build"));
    let _ = fs::remove_dir_all(fixture_dir.join("ct-traces"));
    let _ = fs::remove_dir_all(fixture_dir.join("ct-traces-parse-transform"));
    let checkouts = fixture_dir.join("_checkouts");
    fs::create_dir_all(&checkouts).expect("create fixture _checkouts");
    let checkout_link = checkouts.join("rebar3_codetracer");
    let _ = fs::remove_file(&checkout_link);
    let _ = fs::remove_dir_all(&checkout_link);
    std::os::unix::fs::symlink(repo_root().join("rebar3_codetracer"), &checkout_link)
        .expect("link local rebar3_codetracer plugin checkout");

    let mut args = vec![
        "as",
        profile,
        "codetracer",
        "--out-dir",
        out_dir.to_str().unwrap(),
        "--build-dir",
        build_dir.to_str().unwrap(),
    ];
    args.extend_from_slice(extra_args);

    let output = Command::new("rebar3")
        .args(args)
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .env("CODETRACER_ELIXIR_RECORDER_BIN", recorder_binary())
        .output()
        .expect("run rebar3 codetracer provider");

    RecordedTrace {
        out_dir,
        build_dir: Some(build_dir),
        output,
    }
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

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
}

fn record_erlang_fixture_function(
    label: &str,
    fixture_name: &str,
    module: &str,
    function: &str,
) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang").join(fixture_name);
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_sources(&fixture_dir.join("src"), &ebin_dir);

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
            module,
            function,
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("run Erlang fixture under runtime session");

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
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

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
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

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
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

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
}

fn record_erlang_value_matrix_function_with_env(
    label: &str,
    function: &str,
    envs: &[(&str, &str)],
) -> RecordedTrace {
    let tmp = temp_dir(label);
    let out_dir = tmp.join("trace");
    let fixture_dir = repo_root().join("test-programs/erlang/value_matrix");
    let ebin_dir = tmp.join("erlang-ebin");
    compile_erlang_value_matrix_fixture(&ebin_dir);

    let mut command = clean_recorder_command();
    command
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
            "value_matrix",
            function,
            "-s",
            "init",
            "stop",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap());
    for (key, value) in envs {
        command.env(key, value);
    }
    let output = command
        .output()
        .expect("run Erlang value_matrix fixture under runtime session");

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
}

fn record_erlang_value_matrix_function(label: &str, function: &str) -> RecordedTrace {
    record_erlang_value_matrix_function_with_env(label, function, &[])
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

    RecordedTrace {
        out_dir,
        build_dir: None,
        output,
    }
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

fn source_map_jsons(out_dir: &Path) -> Vec<Value> {
    let root = out_dir.join("recorder_metadata/source_maps");
    let mut paths = fs::read_dir(&root)
        .unwrap_or_else(|error| panic!("read {}: {error}", root.display()))
        .map(|entry| entry.expect("source-map entry").path())
        .collect::<Vec<_>>();
    paths.sort();
    paths
        .into_iter()
        .map(|path| {
            let text = fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
            serde_json::from_str(&text).expect("source-map JSON")
        })
        .collect()
}

fn compiler_trace_events(recorded: &RecordedTrace) -> Vec<Value> {
    let build_dir = recorded
        .build_dir
        .as_ref()
        .expect("recorded Mix trace should retain codetracer build dir");
    let path = build_dir.join("compiler_traces/events.jsonl");
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    text.lines()
        .map(|line| serde_json::from_str(line).expect("compiler trace JSON line"))
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

fn sidecar_variable_binds(out_dir: &Path) -> Vec<Value> {
    runtime_sidecar_events(out_dir)
        .into_iter()
        .filter(|event| event["event"] == "variable_bind")
        .collect()
}

fn sidecar_drop_events(out_dir: &Path) -> Vec<Value> {
    runtime_sidecar_events(out_dir)
        .into_iter()
        .filter(|event| event["event"] == "drop_variables")
        .collect()
}

fn assert_sidecar_binding(binds: &[Value], name: &str, value: i64) {
    assert!(
        binds.iter().any(|event| {
            event["name"] == name
                && reader_value_int(&event["value"]) == Some(value)
                && event["frame_id"].as_u64().is_some()
                && event["runtime_variable_id"].as_u64().is_some()
                && event["slot_template"]
                    .as_str()
                    .is_some_and(|slot| slot.contains('#'))
        }),
        "missing sidecar variable binding {name}={value}: {binds:#?}"
    );
}

fn sidecar_binding_values<'a>(binds: &'a [Value], name: &str) -> Vec<&'a Value> {
    binds
        .iter()
        .filter(|event| event["name"] == name)
        .map(|event| &event["value"])
        .collect()
}

fn assert_sidecar_record_binding(
    binds: &[Value],
    name: &str,
    record_tag: &str,
    field_count: usize,
    nested_record_tag: Option<&str>,
) {
    let values = sidecar_binding_values(binds, name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "record"
                && value["record_tag"] == record_tag
                && value["fields"]
                    .as_array()
                    .is_some_and(|fields| fields.len() == field_count)
                && nested_record_tag
                    .map(|tag| sidecar_value_contains_record_tag(value, tag))
                    .unwrap_or(true)
        }),
        "missing sidecar record binding {name}=#{record_tag}{{}} with {field_count} fields: {values:#?}"
    );
}

fn assert_sidecar_map_struct_binding(binds: &[Value], name: &str, field_count: usize) {
    let values = sidecar_binding_values(binds, name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "map_struct"
                && value["fields"]
                    .as_array()
                    .is_some_and(|fields| fields.len() == field_count)
        }),
        "missing sidecar map binding {name} with {field_count} fields: {values:#?}"
    );
}

fn sidecar_value_contains_record_tag(value: &Value, record_tag: &str) -> bool {
    if value["kind"] == "record" && value["record_tag"] == record_tag {
        return true;
    }
    match value {
        Value::Object(map) => map
            .values()
            .any(|nested| sidecar_value_contains_record_tag(nested, record_tag)),
        Value::Array(values) => values
            .iter()
            .any(|nested| sidecar_value_contains_record_tag(nested, record_tag)),
        _ => false,
    }
}

fn assert_sidecar_list_binding(binds: &[Value], name: &str, element_count: usize) {
    let values = sidecar_binding_values(binds, name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "list"
                && value["elements"]
                    .as_array()
                    .is_some_and(|elements| elements.len() == element_count)
        }),
        "missing sidecar list binding {name} with {element_count} elements: {values:#?}"
    );
}

fn reader_value_pairs(out_dir: &Path, trace_file: &str) -> Vec<(String, i64)> {
    let reader = open_named_trace(out_dir, trace_file);
    let varnames = (0..reader.varname_count())
        .map(|id| reader.varname(id).expect("reader varname"))
        .collect::<Vec<_>>();
    let mut pairs = Vec::new();
    for step in 0..reader.step_count() {
        let raw = reader.values_json(step).expect("reader values json");
        let Ok(json) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        collect_reader_value_pairs(&json, &varnames, &mut pairs);
    }
    if pairs.is_empty() {
        pairs.extend(raw_ctfs_value_pairs(out_dir, trace_file));
    }
    pairs
}

fn raw_ctfs_value_pairs(out_dir: &Path, trace_file: &str) -> Vec<(String, i64)> {
    let ct_path = out_dir.join(trace_file);
    let mut reader = CtfsReader::open(&ct_path).expect("open CTFS container");
    let values = reader.read_file("values.dat").expect("read values.dat");
    let offsets = reader.read_file("values.off").expect("read values.off");
    let varnames = raw_ctfs_varnames(&mut reader);
    let mut pairs = Vec::new();
    for record in call_record_slices(&values, &offsets) {
        if std::env::var("DEBUG_M9_VALUES").is_ok() {
            eprintln!("value record bytes: {record:02x?}");
        }
        let nim_pairs = decode_nim_value_record(record, &varnames);
        if !nim_pairs.is_empty() {
            pairs.extend(nim_pairs);
            continue;
        }
        if let Ok(full_values) =
            cbor4ii::serde::from_reader::<Vec<FullValueRecord>, _>(Cursor::new(record))
        {
            for full in full_values {
                if let Some(name) = varnames.get(full.variable_id.0) {
                    if let Some(value) = value_record_int(&full.value) {
                        pairs.push((name.clone(), value));
                    }
                }
            }
            continue;
        }
        if let Ok(full) = cbor4ii::serde::from_reader::<FullValueRecord, _>(Cursor::new(record)) {
            if let Some(name) = varnames.get(full.variable_id.0) {
                if let Some(value) = value_record_int(&full.value) {
                    pairs.push((name.clone(), value));
                }
            }
            continue;
        }
        for offset in 0..record.len() {
            if let Ok(full) =
                cbor4ii::serde::from_reader::<FullValueRecord, _>(Cursor::new(&record[offset..]))
            {
                if let Some(name) = varnames.get(full.variable_id.0) {
                    if let Some(value) = value_record_int(&full.value) {
                        pairs.push((name.clone(), value));
                    }
                }
                break;
            }
        }
    }
    pairs
}

fn decode_nim_value_record(record: &[u8], varnames: &[String]) -> Vec<(String, i64)> {
    if record.len() < 5 || record[0] == 0 {
        return Vec::new();
    }
    let count = usize::from(record[0]);
    let mut cursor = 1;
    let mut pairs = Vec::new();
    for _ in 0..count {
        if cursor + 3 > record.len() {
            break;
        }
        let variable_id = usize::from(record[cursor]);
        let cbor_len = usize::from(record[cursor + 2]);
        let cbor_start = cursor + 3;
        let cbor_end = cbor_start + cbor_len;
        let Some(cbor) = record.get(cbor_start..cbor_end) else {
            break;
        };
        if let Ok(json) = cbor4ii::serde::from_reader::<Value, _>(Cursor::new(cbor)) {
            if let (Some(name), Some(value)) = (varnames.get(variable_id), reader_value_int(&json))
            {
                pairs.push((name.clone(), value));
            }
        }
        cursor = cbor_end;
    }
    pairs
}

fn raw_ctfs_varnames(reader: &mut CtfsReader) -> Vec<String> {
    let Ok(varnames) = reader.read_file("varnames.dat") else {
        return Vec::new();
    };
    let Ok(offsets) = reader.read_file("varnames.off") else {
        return Vec::new();
    };
    call_record_slices(&varnames, &offsets)
        .into_iter()
        .map(|record| String::from_utf8_lossy(record).to_string())
        .collect()
}

fn raw_ctfs_drop_variable_names(out_dir: &Path, trace_file: &str) -> Vec<Vec<String>> {
    let ct_path = out_dir.join(trace_file);
    let events = codetracer_trace_reader::ctfs_reader::read_trace_from_ctfs(&ct_path)
        .unwrap_or_else(|error| {
            panic!(
                "read raw CTFS low-level events from {}: {error}",
                ct_path.display()
            )
        });
    let mut varnames = Vec::new();
    let mut drops = Vec::new();
    for event in events {
        match event {
            TraceLowLevelEvent::VariableName(name) | TraceLowLevelEvent::Variable(name) => {
                varnames.push(name);
            }
            TraceLowLevelEvent::DropVariables(variable_ids) => {
                drops.push(
                    variable_ids
                        .into_iter()
                        .map(|variable_id| {
                            varnames
                                .get(variable_id.0)
                                .cloned()
                                .unwrap_or_else(|| format!("<unknown:{}>", variable_id.0))
                        })
                        .collect(),
                );
            }
            _ => {}
        }
    }
    drops
}

fn raw_ctfs_low_level_values(out_dir: &Path, trace_file: &str) -> Vec<(String, ValueRecord)> {
    let ct_path = out_dir.join(trace_file);
    let events = codetracer_trace_reader::ctfs_reader::read_trace_from_ctfs(&ct_path)
        .unwrap_or_else(|error| {
            panic!(
                "read raw CTFS low-level events from {}: {error}",
                ct_path.display()
            )
        });
    let mut varnames = Vec::new();
    let mut values = Vec::new();
    for event in events {
        match event {
            TraceLowLevelEvent::VariableName(name) | TraceLowLevelEvent::Variable(name) => {
                varnames.push(name);
            }
            TraceLowLevelEvent::Value(full) => {
                let name = varnames
                    .get(full.variable_id.0)
                    .cloned()
                    .unwrap_or_else(|| format!("<unknown:{}>", full.variable_id.0));
                values.push((name, full.value));
            }
            _ => {}
        }
    }
    values
}

fn raw_ctfs_low_level_types(out_dir: &Path, trace_file: &str) -> Vec<TypeRecord> {
    let ct_path = out_dir.join(trace_file);
    let events = codetracer_trace_reader::ctfs_reader::read_trace_from_ctfs(&ct_path)
        .unwrap_or_else(|error| {
            panic!(
                "read raw CTFS low-level events from {}: {error}",
                ct_path.display()
            )
        });
    events
        .into_iter()
        .filter_map(|event| match event {
            TraceLowLevelEvent::Type(record) => Some(record),
            _ => None,
        })
        .collect()
}

fn find_named_value<'a>(values: &'a [(String, ValueRecord)], name: &str) -> &'a ValueRecord {
    values
        .iter()
        .rev()
        .find(|(observed, _)| observed == name)
        .map(|(_, value)| value)
        .unwrap_or_else(|| panic!("missing raw CTFS value for {name}: {values:#?}"))
}

fn type_for_value<'a>(value: &ValueRecord, types: &'a [TypeRecord]) -> &'a TypeRecord {
    let type_id = match value {
        ValueRecord::Int { type_id, .. }
        | ValueRecord::Float { type_id, .. }
        | ValueRecord::Bool { type_id, .. }
        | ValueRecord::String { type_id, .. }
        | ValueRecord::Sequence { type_id, .. }
        | ValueRecord::Tuple { type_id, .. }
        | ValueRecord::Struct { type_id, .. }
        | ValueRecord::Variant { type_id, .. }
        | ValueRecord::Reference { type_id, .. }
        | ValueRecord::Raw { type_id, .. }
        | ValueRecord::Error { type_id, .. }
        | ValueRecord::None { type_id }
        | ValueRecord::BigInt { type_id, .. }
        | ValueRecord::Char { type_id, .. } => type_id.0,
        ValueRecord::Cell { .. } => panic!("cell values do not carry a type_id"),
    };
    types
        .get(type_id)
        .unwrap_or_else(|| panic!("missing type_id {type_id} in {types:#?}"))
}

fn assert_value_type(
    values: &[(String, ValueRecord)],
    types: &[TypeRecord],
    name: &str,
    expected_kind: TypeKind,
    expected_lang_type: &str,
) {
    let value = find_named_value(values, name);
    let record = type_for_value(value, types);
    assert_eq!(
        (record.kind, record.lang_type.as_str()),
        (expected_kind, expected_lang_type),
        "unexpected type for {name}: value={value:#?} type={record:#?}"
    );
}

fn assert_raw_ctfs_drop(drops: &[Vec<String>], name: &str) {
    assert!(
        drops
            .iter()
            .any(|variables| variables.iter().any(|variable| variable == name)),
        "missing raw CTFS DropVariables event for {name}: {drops:#?}"
    );
}

fn value_record_int(value: &ValueRecord) -> Option<i64> {
    match value {
        ValueRecord::Int { i, .. } => Some(*i),
        _ => None,
    }
}

fn collect_reader_value_pairs(value: &Value, varnames: &[String], out: &mut Vec<(String, i64)>) {
    match value {
        Value::Object(map) => {
            let variable_id = map
                .get("variable_id")
                .or_else(|| map.get("variableId"))
                .and_then(Value::as_u64);
            let value_int = map.get("value").and_then(reader_value_int);
            if let (Some(variable_id), Some(value_int)) = (variable_id, value_int) {
                if let Some(name) = varnames.get(variable_id as usize) {
                    out.push((name.clone(), value_int));
                }
            }
            for nested in map.values() {
                collect_reader_value_pairs(nested, varnames, out);
            }
        }
        Value::Array(values) => {
            for nested in values {
                collect_reader_value_pairs(nested, varnames, out);
            }
        }
        _ => {}
    }
}

fn reader_value_int(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number.as_i64(),
        Value::Object(map) => map.get("value").and_then(reader_value_int).or_else(|| {
            map.get("i")
                .or_else(|| map.get("Int"))
                .and_then(Value::as_i64)
        }),
        Value::Array(values) => values.iter().find_map(reader_value_int),
        _ => None,
    }
}

fn sidecar_value_display(value: &Value) -> String {
    reader_value_int(value)
        .map(|number| number.to_string())
        .unwrap_or_else(|| value.to_string())
}

fn assert_reader_value(pairs: &[(String, i64)], name: &str, value: i64) {
    assert!(
        pairs.iter().any(
            |(observed_name, observed_value)| observed_name == name && *observed_value == value
        ),
        "missing CTFS reader value {name}={value}: {pairs:#?}"
    );
}

fn normalized_elixir_variable_name(name: &str) -> &str {
    let stripped = name.strip_prefix('_').unwrap_or(name);
    stripped.split('@').next().unwrap_or(stripped)
}

fn sidecar_elixir_binding_values<'a>(binds: &'a [Value], source_name: &str) -> Vec<&'a Value> {
    binds
        .iter()
        .filter(|event| {
            event["source_language"] == "elixir"
                && event["name"]
                    .as_str()
                    .is_some_and(|name| normalized_elixir_variable_name(name) == source_name)
        })
        .map(|event| &event["value"])
        .collect()
}

fn assert_sidecar_elixir_binding(binds: &[Value], source_name: &str, value: i64) {
    assert!(
        binds.iter().any(|event| {
            event["source_language"] == "elixir"
                && event["name"]
                    .as_str()
                    .is_some_and(|name| normalized_elixir_variable_name(name) == source_name)
                && reader_value_int(&event["value"]) == Some(value)
                && event["frame_id"].as_u64().is_some()
                && event["runtime_variable_id"].as_u64().is_some()
                && event["slot_template"]
                    .as_str()
                    .is_some_and(|slot| slot.contains("Elixir."))
        }),
        "missing sidecar Elixir variable binding {source_name}={value}: {binds:#?}"
    );
}

fn assert_sidecar_elixir_list_binding(binds: &[Value], source_name: &str, element_count: usize) {
    let values = sidecar_elixir_binding_values(binds, source_name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "list"
                && value["elements"]
                    .as_array()
                    .is_some_and(|elements| elements.len() == element_count)
        }),
        "missing sidecar Elixir list binding {source_name} with {element_count} elements: {values:#?}"
    );
}

fn assert_sidecar_elixir_map_struct_binding(
    binds: &[Value],
    source_name: &str,
    field_count: usize,
) {
    let values = sidecar_elixir_binding_values(binds, source_name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "map_struct"
                && value["fields"]
                    .as_array()
                    .is_some_and(|fields| fields.len() == field_count)
        }),
        "missing sidecar Elixir map/struct binding {source_name} with {field_count} fields: {values:#?}"
    );
}

fn assert_sidecar_elixir_string_binding(binds: &[Value], source_name: &str, text: &str) {
    let values = sidecar_elixir_binding_values(binds, source_name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "string" && value["value"] == text && value["lang_type"] == "binary"
        }),
        "missing sidecar Elixir string binding {source_name}={text:?}: {values:#?}"
    );
}

fn assert_sidecar_elixir_raw_binding(
    binds: &[Value],
    source_name: &str,
    lang_type: &str,
    predicate: impl Fn(&str) -> bool,
) {
    let values = sidecar_elixir_binding_values(binds, source_name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "raw"
                && value["lang_type"] == lang_type
                && value["value"].as_str().is_some_and(&predicate)
        }),
        "missing sidecar Elixir raw binding {source_name} with lang_type {lang_type}: {values:#?}"
    );
}

fn assert_sidecar_elixir_raw_type_binding(
    binds: &[Value],
    source_name: &str,
    type_kind: &str,
    lang_type: &str,
) {
    let values = sidecar_elixir_binding_values(binds, source_name);
    assert!(
        values.iter().any(|value| {
            value["kind"] == "raw"
                && value["type_kind"] == type_kind
                && value["lang_type"] == lang_type
                && value["value"].as_str().is_some_and(|text| !text.is_empty())
        }),
        "missing sidecar Elixir raw {type_kind}/{lang_type} binding {source_name}: {values:#?}"
    );
}

fn assert_reader_elixir_value(pairs: &[(String, i64)], source_name: &str, value: i64) {
    assert!(
        pairs.iter().any(|(observed_name, observed_value)| {
            normalized_elixir_variable_name(observed_name) == source_name
                && *observed_value == value
        }),
        "missing CTFS reader Elixir value {source_name}={value}: {pairs:#?}"
    );
}

fn assert_raw_elixir_value(
    values: &[(String, ValueRecord)],
    source_name: &str,
    description: &str,
    predicate: impl Fn(&ValueRecord) -> bool,
) {
    let matches = values
        .iter()
        .filter(|(observed_name, _)| normalized_elixir_variable_name(observed_name) == source_name)
        .map(|(_, value)| value)
        .collect::<Vec<_>>();
    assert!(
        matches.iter().any(|value| predicate(value)),
        "missing raw CTFS Elixir value {source_name} matching {description}: {matches:#?}"
    );
}

fn find_elixir_named_value<'a>(
    values: &'a [(String, ValueRecord)],
    source_name: &str,
) -> &'a ValueRecord {
    values
        .iter()
        .rev()
        .find(|(observed_name, _)| normalized_elixir_variable_name(observed_name) == source_name)
        .map(|(_, value)| value)
        .unwrap_or_else(|| panic!("missing raw CTFS Elixir value for {source_name}: {values:#?}"))
}

fn assert_elixir_value_type(
    values: &[(String, ValueRecord)],
    types: &[TypeRecord],
    source_name: &str,
    expected_kind: TypeKind,
    expected_lang_type: &str,
) {
    let value = find_elixir_named_value(values, source_name);
    let record = type_for_value(value, types);
    assert_eq!(
        (record.kind, record.lang_type.as_str()),
        (expected_kind, expected_lang_type),
        "unexpected Elixir type for {source_name}: value={value:#?} type={record:#?}"
    );
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
                sidecar_value_display(&event["return_value"])
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
fn e2e_erlang_receive_matrix_process_constructs() {
    let recorded = record_erlang_fixture_function(
        "m13-erlang-receive-matrix",
        "receive_matrix",
        "receive_matrix",
        "main",
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "receive-matrix-ok\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    let messages = sidecar_message_events(&events);

    let selective_send = find_message_event(&messages, "send", "selective_receive");
    let selective_receive = find_message_event(&messages, "receive", "selective_receive");
    let leftover_send = find_message_event(&messages, "send", "leftover_message");
    let leftover_receive = find_message_event(&messages, "receive", "leftover_message");
    let timeout_send = find_message_event(&messages, "send", "timeout_result");
    let timeout_receive = find_message_event(&messages, "receive", "timeout_result");
    let registered_send = find_message_event(&messages, "send", "registered_send");
    let registered_receive = find_message_event(&messages, "receive", "registered_send");
    let spawn3_ready_send = find_message_event(&messages, "send", "spawn3_ready");
    let spawn3_ready_receive = find_message_event(&messages, "receive", "spawn3_ready");
    let spawn3_request_send = find_message_event(&messages, "send", "spawn3_request");
    let spawn3_request_receive = find_message_event(&messages, "receive", "spawn3_request");
    let spawn3_result_send = find_message_event(&messages, "send", "spawn3_result");
    let spawn3_result_receive = find_message_event(&messages, "receive", "spawn3_result");
    let linked_done_send = find_message_event(&messages, "send", "linked_worker_done");
    let linked_done_receive = find_message_event(&messages, "receive", "linked_worker_done");
    let linked_exit_receive = find_message_event(&messages, "receive", "EXIT");
    let monitor_done_send = find_message_event(&messages, "send", "monitor_worker_done");
    let monitor_done_receive = find_message_event(&messages, "receive", "monitor_worker_done");
    let monitor_down_receive = find_message_event(&messages, "receive", "DOWN");

    assert_eq!(selective_send["recipient_thread_id"], 1);
    assert_eq!(selective_receive["recipient_thread_id"], 1);
    assert_eq!(leftover_send["recipient_thread_id"], 1);
    assert_eq!(leftover_receive["recipient_thread_id"], 1);
    assert_eq!(timeout_send["recipient_thread_id"], 1);
    assert_eq!(timeout_receive["recipient_thread_id"], 1);
    assert_eq!(registered_receive["recipient_thread_id"], 1);
    assert_eq!(linked_exit_receive["recipient_thread_id"], 1);
    assert_eq!(monitor_down_receive["recipient_thread_id"], 1);
    assert_eq!(
        registered_send["sender_thread_id"],
        registered_receive["sender_thread_id"]
    );
    assert_eq!(
        spawn3_ready_send["sender_pid"],
        spawn3_ready_receive["sender_pid"]
    );
    assert_eq!(
        spawn3_request_send["recipient_pid"],
        spawn3_request_receive["recipient_pid"]
    );
    assert_eq!(
        spawn3_result_send["sender_pid"],
        spawn3_result_receive["sender_pid"]
    );
    assert_eq!(
        linked_done_send["sender_pid"],
        linked_done_receive["sender_pid"]
    );
    assert_eq!(
        monitor_done_send["sender_pid"],
        monitor_done_receive["sender_pid"]
    );

    let spawn3_thread_id = spawn3_request_receive["recipient_thread_id"]
        .as_u64()
        .expect("spawn/3 worker thread id");
    let linked_thread_id = linked_done_send["sender_thread_id"]
        .as_u64()
        .expect("linked worker thread id");
    let monitor_thread_id = monitor_done_send["sender_thread_id"]
        .as_u64()
        .expect("monitored worker thread id");

    let starts = sidecar_thread_ids(&events, "thread_start");
    let exits = sidecar_thread_ids(&events, "thread_exit");
    let switches = sidecar_thread_ids(&events, "thread_switch");
    for (label, thread_id) in [
        ("spawn/3 worker", spawn3_thread_id),
        ("linked worker", linked_thread_id),
        ("monitored worker", monitor_thread_id),
    ] {
        assert!(
            starts.contains(&thread_id),
            "{label} should have ThreadStart: {events:#?}"
        );
        assert!(
            exits.contains(&thread_id),
            "{label} should have ThreadExit: {events:#?}"
        );
        assert!(
            switches.contains(&thread_id),
            "{label} should have ThreadSwitch: {events:#?}"
        );
        assert_reader_thread_event(&recorded.out_dir, "erl.ct", "thread_start", thread_id);
        assert_reader_thread_event(&recorded.out_dir, "erl.ct", "thread_switch", thread_id);
        assert_reader_thread_event(&recorded.out_dir, "erl.ct", "thread_exit", thread_id);
    }

    assert_reader_trace_log_contains(
        &recorded.out_dir,
        "erl.ct",
        &[
            "selective_receive",
            "leftover_message",
            "timeout_result",
            "registered_send",
            "spawn3_ready",
            "spawn3_request",
            "spawn3_result",
            "linked_worker_done",
            "EXIT",
            "monitor_worker_done",
            "DOWN",
        ],
    );
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
        RecordedTrace {
            out_dir,
            build_dir: None,
            output,
        }
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
fn e2e_mix_records_basic_elixir_app() {
    let recorded =
        record_mix_task_eval("m12-basic-mix", "basic_mix_app", "BasicMixApp.main()", &[]);
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        String::from_utf8_lossy(&recorded.output.stdout).contains("basic-ok:42"),
        "{}",
        output_text(&recorded.output)
    );

    let compiler_events = compiler_trace_events(&recorded);
    assert!(
        compiler_events.iter().any(|event| {
            event["event"] == "on_module"
                && event["env"]["file"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("lib/basic_mix_app.ex"))
                && event["env"]["module"] == "Elixir.BasicMixApp"
                && event["payload"]["bytecode_size"]
                    .as_u64()
                    .is_some_and(|size| size > 0)
        }),
        "real compiler tracer should record :on_module completion events: {compiler_events:#?}"
    );
    assert!(
        compiler_events.iter().any(|event| {
            let env = event["env"].as_object().expect("compiler trace env object");
            event["event"] == "imported_function"
                && env
                    .get("file")
                    .and_then(Value::as_str)
                    .is_some_and(|path| path.ends_with("lib/basic_mix_app.ex"))
                && env.get("line").and_then(Value::as_i64) == Some(4)
                && env.get("module") == Some(&Value::String("Elixir.BasicMixApp".to_string()))
                && env.get("function") == Some(&Value::String("compute/1".to_string()))
                && env.contains_key("context")
                && env.get("lexical_tracker").and_then(Value::as_str).is_some()
        }),
        "real compiler tracer should capture Macro.Env file/line/module/function/context/lexical tracker: {compiler_events:#?}"
    );

    let meta = trace_meta(&recorded.out_dir);
    assert!(
        meta["sources"].as_array().is_some_and(|sources| {
            sources.iter().any(|source| {
                source["trace_copy_path"] == "files/lib/basic_mix_app.ex"
                    && source["build_path"]
                        .as_str()
                        .is_some_and(|path| path.ends_with("lib/basic_mix_app.ex"))
            })
        }),
        "trace metadata should list copied original Elixir source: {meta:#?}"
    );
    assert!(recorded
        .out_dir
        .join("files/lib/basic_mix_app.ex")
        .is_file());
    assert!(
        recorded
            .out_dir
            .join("recorder_metadata/source_maps")
            .is_dir(),
        "trace bundle should contain real source-map artifacts"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.BasicMixApp")
        .unwrap_or_else(|| panic!("missing BasicMixApp manifest: {manifests:#?}"));
    assert!(
        manifest["locations"].as_array().is_some_and(|locations| {
            locations.iter().any(|location| {
                location["resolution"] == "source_map"
                    && location["trace_copy_path"] == "files/lib/basic_mix_app.ex"
            })
        }),
        "Mix source locations should resolve to original .ex files: {manifest:#?}"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "Elixir.BasicMixApp"
                && event["function"] == "compute"
                && event["source_location"]["resolution"] == "source_map"
        }),
        "runtime should record calls with source-map metadata: {events:#?}"
    );
    assert!(
        events.iter().any(|event| event["event"] == "step"),
        "instrumented Mix app should emit real step events: {events:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "mix.ct");
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    assert!(
        paths
            .iter()
            .any(|path| path.ends_with("lib/basic_mix_app.ex")),
        "CTFS reader should expose original Elixir paths: {paths:#?}"
    );
    assert!(
        !raw_ctfs_call_return_values(&recorded.out_dir).is_empty(),
        "raw CTFS calls.dat should contain real Mix call records"
    );
}

#[test]
fn e2e_elixir_constructs_core_matrix() {
    let recorded = record_mix_task_eval(
        "m13-elixir-constructs-core",
        "constructs_core",
        "ConstructsCore.main()",
        &[],
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        String::from_utf8_lossy(&recorded.output.stdout).contains("constructs-core-ok:674"),
        "{}",
        output_text(&recorded.output)
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    for (function, arity) in [
        ("main", 0),
        ("pattern_matrix", 0),
        ("access_matrix", 0),
        ("branch_matrix", 1),
        ("defaults_matrix", 1),
        ("defaults_matrix", 3),
        ("classify", 1),
        ("with_matrix", 1),
        ("fetch_piece", 2),
    ] {
        assert!(
            events.iter().any(|event| {
                event["event"] == "call"
                    && event["module"] == "Elixir.ConstructsCore"
                    && event["function"] == function
                    && event["arity"] == arity
                    && event["source_location"]["trace_copy_path"]
                        == "files/lib/constructs_core.ex"
                    && event["source_location"]["resolution"] == "source_map"
            }),
            "runtime sidecar should include public call Elixir.ConstructsCore.{function}/{arity} with source-map metadata: {events:#?}"
        );
    }
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "Elixir.ConstructsCore"
                && event["function"] == "private_offset"
                && event["arity"] == 1
        }),
        "private defp should be exercised by the real trace: {events:#?}"
    );

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("list_head", 10),
        ("list_third", 30),
        ("map_left", 21),
        ("nested_score", 5),
        ("binary_digit", 55),
        ("struct_id", 7),
        ("struct_zip", 4242),
        ("nested_head", 3),
        ("nested_value", 9),
        ("pinned_amount", 8),
        ("list_result", 42),
        ("map_result", 26),
        ("binary_result", 61),
        ("struct_result", 11),
        ("pattern_score", 160),
        ("access_total", 56),
        ("with_success", 25),
        ("with_else", 9),
        ("branch_score", 64),
        ("defaults_score", 13),
        ("guard_score", 117),
        ("binary_guard_score", 204),
        ("private_score", 36),
        ("final_total", 674),
    ] {
        assert_sidecar_elixir_binding(&binds, name, value);
    }
    assert_sidecar_elixir_list_binding(&binds, "list_rest", 2);
    assert_sidecar_elixir_string_binding(&binds, "binary_prefix", "ct");
    assert_sidecar_elixir_string_binding(&binds, "binary_tail", "core");
    assert_sidecar_elixir_map_struct_binding(&binds, "base_struct", 5);
    assert_sidecar_elixir_map_struct_binding(&binds, "updated_map", 3);
    assert_sidecar_elixir_map_struct_binding(&binds, "update_map", 3);
    assert_sidecar_elixir_map_struct_binding(&binds, "updated_struct", 5);

    let meta = trace_meta(&recorded.out_dir);
    assert!(
        meta["sources"].as_array().is_some_and(|sources| {
            sources.iter().any(|source| {
                source["trace_copy_path"] == "files/lib/constructs_core.ex"
                    && source["build_path"]
                        .as_str()
                        .is_some_and(|path| path.ends_with("lib/constructs_core.ex"))
            })
        }),
        "trace metadata should expose the ConstructsCore .ex source: {meta:#?}"
    );
    assert!(
        recorded
            .out_dir
            .join("files/lib/constructs_core.ex")
            .is_file(),
        "trace bundle should copy lib/constructs_core.ex"
    );

    let source_maps = source_map_jsons(&recorded.out_dir);
    assert!(
        source_maps.iter().any(|map| {
            map["source_language"] == "elixir"
                && map["original_path"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("lib/constructs_core.ex"))
                && map["mappings"]
                    .as_array()
                    .is_some_and(|mappings| !mappings.is_empty())
        }),
        "source-map artifacts should map generated Erlang forms back to lib/constructs_core.ex: {source_maps:#?}"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.ConstructsCore")
        .unwrap_or_else(|| panic!("missing ConstructsCore manifest: {manifests:#?}"));
    assert!(
        manifest["functions"].as_array().is_some_and(|functions| {
            [
                "Elixir.ConstructsCore.main/0",
                "Elixir.ConstructsCore.pattern_matrix/0",
                "Elixir.ConstructsCore.access_matrix/0",
                "Elixir.ConstructsCore.branch_matrix/1",
                "Elixir.ConstructsCore.defaults_matrix/1",
                "Elixir.ConstructsCore.defaults_matrix/3",
                "Elixir.ConstructsCore.classify/1",
                "Elixir.ConstructsCore.with_matrix/1",
                "Elixir.ConstructsCore.fetch_piece/2",
                "Elixir.ConstructsCore.private_offset/1",
            ]
            .into_iter()
            .all(|key| functions.iter().any(|function| function["key"] == key))
        }) && manifest["locations"].as_array().is_some_and(|locations| {
            locations.iter().any(|location| {
                location["trace_copy_path"] == "files/lib/constructs_core.ex"
                    && location["resolution"] == "source_map"
            })
        }),
        "ConstructsCore manifest should expose functions and .ex source-map locations: {manifest:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "mix.ct");
    assert!(
        reader.step_count() > 0,
        "CTFS reader should expose ConstructsCore steps"
    );
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    assert!(
        paths
            .iter()
            .any(|path| path.ends_with("lib/constructs_core.ex")),
        "CTFS reader paths should include lib/constructs_core.ex: {paths:#?}"
    );
    let function_names = reader_function_names(&reader);
    assert!(
        function_names
            .iter()
            .any(|name| name == "ConstructsCore.main/0")
            && function_names
                .iter()
                .any(|name| name == "ConstructsCore.pattern_matrix/0")
            && function_names
                .iter()
                .any(|name| name == "ConstructsCore.access_matrix/0"),
        "CTFS reader should expose ConstructsCore functions: {function_names:#?}"
    );
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name == "ConstructsCore.with_matrix/1")
            && call_names
                .iter()
                .any(|name| name == "ConstructsCore.fetch_piece/2"),
        "CTFS reader should expose calls across with/else flow: {call_names:#?}"
    );
    let pairs = reader_value_pairs(&recorded.out_dir, "mix.ct");
    for (name, value) in [
        ("list_result", 42),
        ("map_result", 26),
        ("binary_result", 61),
        ("struct_result", 11),
        ("final_total", 674),
    ] {
        assert_reader_elixir_value(&pairs, name, value);
    }

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "mix.ct");
    assert_raw_elixir_value(
        &values,
        "list_rest",
        "list with two tail elements",
        |value| matches!(value, ValueRecord::Sequence { elements, .. } if elements.len() == 2),
    );
    assert_raw_elixir_value(
        &values,
        "binary_tail",
        "binary tail string",
        |value| matches!(value, ValueRecord::String { text, .. } if text == "core"),
    );
    assert_raw_elixir_value(
        &values,
        "base_struct",
        "Elixir struct map",
        |value| matches!(value, ValueRecord::Struct { field_values, .. } if field_values.len() == 5),
    );
    assert_raw_elixir_value(
        &values,
        "updated_map",
        "updated map",
        |value| matches!(value, ValueRecord::Struct { field_values, .. } if field_values.len() == 3),
    );
    assert_raw_elixir_value(&values, "final_total", "final integer total", |value| {
        matches!(value, ValueRecord::Int { i: 674, .. })
    });

    let mut raw_reader =
        CtfsReader::open(&recorded.out_dir.join("mix.ct")).expect("open raw CTFS trace");
    for file in ["paths.dat", "calls.dat", "values.dat"] {
        let payload = raw_reader
            .read_file(file)
            .unwrap_or_else(|error| panic!("read raw CTFS {file}: {error}"));
        assert!(!payload.is_empty(), "raw CTFS {file} should be non-empty");
    }
}

#[test]
fn e2e_elixir_values_comprehensions_matrix() {
    let recorded = record_mix_task_eval(
        "m14-elixir-values-comprehensions",
        "values_comprehensions",
        "ValuesComprehensions.main()",
        &[],
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        String::from_utf8_lossy(&recorded.output.stdout).contains("values-comprehensions-ok:381"),
        "{}",
        output_text(&recorded.output)
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    for (function, arity) in [
        ("main", 0),
        ("value_matrix", 0),
        ("list_comprehension_matrix", 0),
        ("binary_bitstring_matrix", 0),
        ("option_matrix", 0),
        ("capture_matrix", 0),
    ] {
        assert!(
            events.iter().any(|event| {
                event["event"] == "call"
                    && event["module"] == "Elixir.ValuesComprehensions"
                    && event["function"] == function
                    && event["arity"] == arity
                    && event["source_location"]["trace_copy_path"]
                        == "files/lib/values_comprehensions.ex"
                    && event["source_location"]["resolution"] == "source_map"
            }),
            "runtime sidecar should include Elixir.ValuesComprehensions.{function}/{arity} with source-map metadata: {events:#?}"
        );
    }

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("values_score", 44),
        ("list_score", 124),
        ("binary_score", 137),
        ("options_score", 43),
        ("capture_score", 33),
        ("final_total", 381),
        ("last_byte", 99),
        ("three", 5),
        ("five", 17),
        ("two", 3),
        ("reduced_sum", 16),
        ("capture_value", 7),
        ("capture_result", 17),
        ("regex_bonus", 11),
    ] {
        assert_sidecar_elixir_binding(&binds, name, value);
    }
    for (name, count) in [
        ("charlist_value", 4),
        ("sigil_words", 2),
        ("list_filtered", 3),
        ("nested_pairs", 3),
        ("map_gen_list", 2),
        ("unique_values", 3),
        ("capture_lengths", 2),
        ("capture_values", 3),
    ] {
        assert_sidecar_elixir_list_binding(&binds, name, count);
    }
    for (name, text) in [
        ("string_value", "trace"),
        ("sigil_string", "sigiled"),
        ("captured_string", "CT"),
        ("prefix", "ab"),
        ("binary_comprehension", "ACE"),
        ("into_binary", "bcd"),
    ] {
        assert_sidecar_elixir_string_binding(&binds, name, text);
    }
    assert_sidecar_elixir_map_struct_binding(&binds, "map_value", 3);
    assert_sidecar_elixir_map_struct_binding(&binds, "struct_value", 4);
    assert_sidecar_elixir_map_struct_binding(&binds, "into_map", 2);
    assert_sidecar_elixir_raw_binding(&binds, "raw_binary", "binary", |value| {
        value == "0x00FF4105"
    });
    assert_sidecar_elixir_raw_binding(&binds, "raw_tail", "binary", |value| value == "0xFF4105");
    assert_sidecar_elixir_raw_binding(&binds, "bitstring_value", "term", |value| {
        value.starts_with("<<")
    });
    for name in ["remote_capture", "placeholder_capture", "mapper_capture"] {
        assert_sidecar_elixir_raw_type_binding(&binds, name, "FunctionKind", "fun");
    }

    let meta = trace_meta(&recorded.out_dir);
    assert!(
        meta["sources"].as_array().is_some_and(|sources| {
            sources.iter().any(|source| {
                source["trace_copy_path"] == "files/lib/values_comprehensions.ex"
                    && source["build_path"]
                        .as_str()
                        .is_some_and(|path| path.ends_with("lib/values_comprehensions.ex"))
            })
        }),
        "trace metadata should expose the ValuesComprehensions .ex source: {meta:#?}"
    );
    assert!(
        recorded
            .out_dir
            .join("files/lib/values_comprehensions.ex")
            .is_file(),
        "trace bundle should copy lib/values_comprehensions.ex"
    );

    let source_maps = source_map_jsons(&recorded.out_dir);
    assert!(
        source_maps.iter().any(|map| {
            map["source_language"] == "elixir"
                && map["original_path"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("lib/values_comprehensions.ex"))
                && map["mappings"]
                    .as_array()
                    .is_some_and(|mappings| !mappings.is_empty())
        }),
        "source-map artifacts should map generated Erlang forms back to lib/values_comprehensions.ex: {source_maps:#?}"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.ValuesComprehensions")
        .unwrap_or_else(|| panic!("missing ValuesComprehensions manifest: {manifests:#?}"));
    assert!(
        manifest["functions"].as_array().is_some_and(|functions| {
            [
                "Elixir.ValuesComprehensions.main/0",
                "Elixir.ValuesComprehensions.value_matrix/0",
                "Elixir.ValuesComprehensions.list_comprehension_matrix/0",
                "Elixir.ValuesComprehensions.binary_bitstring_matrix/0",
                "Elixir.ValuesComprehensions.option_matrix/0",
                "Elixir.ValuesComprehensions.capture_matrix/0",
            ]
            .into_iter()
            .all(|key| functions.iter().any(|function| function["key"] == key))
        }) && manifest["locations"].as_array().is_some_and(|locations| {
            locations.iter().any(|location| {
                location["trace_copy_path"] == "files/lib/values_comprehensions.ex"
                    && location["resolution"] == "source_map"
            })
        }),
        "ValuesComprehensions manifest should expose functions and .ex source-map locations: {manifest:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "mix.ct");
    assert!(
        reader.step_count() > 0,
        "CTFS reader should expose ValuesComprehensions steps"
    );
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    assert!(
        paths
            .iter()
            .any(|path| path.ends_with("lib/values_comprehensions.ex")),
        "CTFS reader paths should include lib/values_comprehensions.ex: {paths:#?}"
    );
    let function_names = reader_function_names(&reader);
    assert!(
        [
            "ValuesComprehensions.main/0",
            "ValuesComprehensions.value_matrix/0",
            "ValuesComprehensions.list_comprehension_matrix/0",
            "ValuesComprehensions.binary_bitstring_matrix/0",
            "ValuesComprehensions.option_matrix/0",
            "ValuesComprehensions.capture_matrix/0",
        ]
        .into_iter()
        .all(|expected| function_names.iter().any(|name| name == expected)),
        "CTFS reader should expose ValuesComprehensions functions: {function_names:#?}"
    );
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name == "ValuesComprehensions.binary_bitstring_matrix/0")
            && call_names
                .iter()
                .any(|name| name == "ValuesComprehensions.option_matrix/0")
            && call_names
                .iter()
                .any(|name| name == "ValuesComprehensions.capture_matrix/0"),
        "CTFS reader should expose ValuesComprehensions call records: {call_names:#?}"
    );
    let pairs = reader_value_pairs(&recorded.out_dir, "mix.ct");
    for (name, value) in [
        ("values_score", 44),
        ("list_score", 124),
        ("binary_score", 137),
        ("options_score", 43),
        ("capture_score", 33),
        ("final_total", 381),
    ] {
        assert_reader_elixir_value(&pairs, name, value);
    }

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "mix.ct");
    let types = raw_ctfs_low_level_types(&recorded.out_dir, "mix.ct");
    assert_raw_elixir_value(
        &values,
        "string_value",
        "string binary",
        |value| matches!(value, ValueRecord::String { text, .. } if text == "trace"),
    );
    assert_raw_elixir_value(
        &values,
        "charlist_value",
        "charlist sequence",
        |value| matches!(value, ValueRecord::Sequence { elements, .. } if elements.len() == 4),
    );
    assert_raw_elixir_value(
        &values,
        "sigil_string",
        "sigil string",
        |value| matches!(value, ValueRecord::String { text, .. } if text == "sigiled"),
    );
    assert_raw_elixir_value(
        &values,
        "map_value",
        "map value",
        |value| matches!(value, ValueRecord::Struct { field_values, .. } if field_values.len() == 3),
    );
    assert_raw_elixir_value(
        &values,
        "struct_value",
        "Elixir struct value",
        |value| matches!(value, ValueRecord::Struct { field_values, .. } if field_values.len() == 4),
    );
    assert_raw_elixir_value(
        &values,
        "raw_binary",
        "raw binary",
        |value| matches!(value, ValueRecord::Raw { r, .. } if r == "0x00FF4105"),
    );
    assert_raw_elixir_value(
        &values,
        "binary_comprehension",
        "binary comprehension string",
        |value| matches!(value, ValueRecord::String { text, .. } if text == "ACE"),
    );
    assert_raw_elixir_value(
        &values,
        "bitstring_comprehension",
        "non-byte-size bitstring comprehension",
        |value| matches!(value, ValueRecord::Raw { r, .. } if r.starts_with("<<")),
    );
    assert_raw_elixir_value(
        &values,
        "into_map",
        "into map",
        |value| matches!(value, ValueRecord::Struct { field_values, .. } if field_values.len() == 2),
    );
    assert_raw_elixir_value(
        &values,
        "into_binary",
        "into binary",
        |value| matches!(value, ValueRecord::String { text, .. } if text == "bcd"),
    );
    for name in ["remote_capture", "placeholder_capture", "mapper_capture"] {
        assert_raw_elixir_value(&values, name, "function capture", |value| {
            matches!(value, ValueRecord::Raw { .. })
        });
    }
    assert_raw_elixir_value(&values, "final_total", "final integer total", |value| {
        matches!(value, ValueRecord::Int { i: 381, .. })
    });

    assert_elixir_value_type(&values, &types, "string_value", TypeKind::String, "binary");
    assert_elixir_value_type(&values, &types, "charlist_value", TypeKind::Seq, "list");
    assert_elixir_value_type(&values, &types, "map_value", TypeKind::Struct, "map");
    assert_elixir_value_type(&values, &types, "struct_value", TypeKind::Struct, "map");
    assert_elixir_value_type(&values, &types, "raw_binary", TypeKind::Raw, "binary");
    assert_elixir_value_type(
        &values,
        &types,
        "binary_comprehension",
        TypeKind::String,
        "binary",
    );
    assert_elixir_value_type(
        &values,
        &types,
        "remote_capture",
        TypeKind::FunctionKind,
        "fun",
    );
    assert_elixir_value_type(
        &values,
        &types,
        "placeholder_capture",
        TypeKind::FunctionKind,
        "fun",
    );
}

#[test]
fn e2e_elixir_protocol_macro_behaviour_matrix() {
    let recorded = record_mix_task_eval(
        "m15-elixir-protocol-macro-behaviour",
        "protocol_macro_behaviour",
        "ProtocolMacroBehaviour.main()",
        &[],
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        String::from_utf8_lossy(&recorded.output.stdout)
            .contains("protocol-macro-behaviour-ok:549"),
        "{}",
        output_text(&recorded.output)
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    for (module, function, arity, path) in [
        (
            "Elixir.ProtocolMacroBehaviour",
            "main",
            0,
            "files/lib/protocol_macro_behaviour.ex",
        ),
        (
            "Elixir.ProtocolMacroBehaviour",
            "protocol_matrix",
            0,
            "files/lib/protocol_macro_behaviour.ex",
        ),
        (
            "Elixir.ProtocolMacroBehaviour",
            "macro_matrix",
            1,
            "files/lib/protocol_macro_behaviour.ex",
        ),
        (
            "Elixir.ProtocolMacroBehaviour",
            "behaviour_matrix",
            1,
            "files/lib/protocol_macro_behaviour.ex",
        ),
        (
            "Elixir.ProtocolMacroBehaviour.UsingWorker",
            "perform",
            1,
            "files/lib/protocol_macro_behaviour.ex",
        ),
        (
            "Elixir.ProtocolMacroBehaviour.UsingWorker",
            "overridable_score",
            1,
            "files/lib/protocol_macro_behaviour.ex",
        ),
        (
            "Elixir.ProtocolMacroBehaviour.UsingWorker",
            "macro_generated_score",
            1,
            "files/lib/protocol_macro_behaviour.ex",
        ),
        (
            "Elixir.ProtocolMacroBehaviour.Imported",
            "imported_bonus",
            1,
            "files/lib/protocol_macro_behaviour/macros.ex",
        ),
    ] {
        assert!(
            events.iter().any(|event| {
                event["event"] == "call"
                    && event["module"] == module
                    && event["function"] == function
                    && event["arity"] == arity
                    && event["source_location"]["trace_copy_path"] == path
                    && event["source_location"]["resolution"] == "source_map"
            }),
            "runtime sidecar should include {module}.{function}/{arity} with source-map metadata: {events:#?}"
        );
    }

    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "Elixir.ProtocolMacroBehaviour.Renderable"
                && event["function"] == "score"
                && event["arity"] == 1
        }),
        "runtime sidecar should include defprotocol dispatch calls: {events:#?}"
    );
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"].as_str().is_some_and(|module| {
                    module.contains("Renderable.ProtocolMacroBehaviour.ManualItem")
                })
                && event["function"] == "score"
                && event["arity"] == 1
        }),
        "runtime sidecar should include the explicit defimpl path: {events:#?}"
    );
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"].as_str().is_some_and(|module| {
                    module.contains("Renderable.ProtocolMacroBehaviour.DerivedItem")
                        || module == "Elixir.ProtocolMacroBehaviour.Renderable.Any"
                })
                && event["function"] == "score"
                && event["arity"] == 1
        }),
        "runtime sidecar should include the @derive protocol implementation path: {events:#?}"
    );

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("protocol_score", 199),
        ("macro_score", 220),
        ("behaviour_score", 75),
        ("attribute_score", 55),
        ("manual_score", 15),
        ("derived_score", 33),
        ("label_size", 55),
        ("hygiene_score", 125),
        ("generated_score", 24),
        ("bound_from_macro", 65),
        ("perform_score", 43),
        ("super_score", 17),
        ("imported_score", 15),
        ("attr_protocol_score", 48),
        ("final_total", 549),
    ] {
        assert_sidecar_elixir_binding(&binds, name, value);
    }

    let meta = trace_meta(&recorded.out_dir);
    for path in [
        "files/lib/protocol_macro_behaviour.ex",
        "files/lib/protocol_macro_behaviour/macros.ex",
    ] {
        assert!(
            meta["sources"].as_array().is_some_and(|sources| {
                sources
                    .iter()
                    .any(|source| source["trace_copy_path"] == path)
            }),
            "trace metadata should expose fixture source {path}: {meta:#?}"
        );
        assert!(
            recorded.out_dir.join(path).is_file(),
            "trace bundle should copy {path}"
        );
    }

    let source_maps = source_map_jsons(&recorded.out_dir);
    for path in [
        "lib/protocol_macro_behaviour.ex",
        "lib/protocol_macro_behaviour/macros.ex",
    ] {
        assert!(
            source_maps.iter().any(|map| {
                map["source_language"] == "elixir"
                    && map["original_path"]
                        .as_str()
                        .is_some_and(|original| original.ends_with(path))
                    && map["mappings"]
                        .as_array()
                        .is_some_and(|mappings| !mappings.is_empty())
            }),
            "source-map artifacts should include {path}: {source_maps:#?}"
        );
    }

    let manifests = manifest_jsons(&recorded.out_dir);
    let main_manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.ProtocolMacroBehaviour")
        .unwrap_or_else(|| panic!("missing ProtocolMacroBehaviour manifest: {manifests:#?}"));
    assert!(
        main_manifest["functions"]
            .as_array()
            .is_some_and(|functions| {
                [
                    "Elixir.ProtocolMacroBehaviour.main/0",
                    "Elixir.ProtocolMacroBehaviour.protocol_matrix/0",
                    "Elixir.ProtocolMacroBehaviour.macro_matrix/1",
                    "Elixir.ProtocolMacroBehaviour.behaviour_matrix/1",
                    "Elixir.ProtocolMacroBehaviour.attribute_matrix/0",
                ]
                .into_iter()
                .all(|key| functions.iter().any(|function| function["key"] == key))
            })
            && main_manifest["locations"]
                .as_array()
                .is_some_and(|locations| {
                    locations.iter().any(|location| {
                        location["trace_copy_path"] == "files/lib/protocol_macro_behaviour.ex"
                            && location["resolution"] == "source_map"
                    })
                }),
        "ProtocolMacroBehaviour manifest should expose source-mapped functions: {main_manifest:#?}"
    );
    let worker_manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.ProtocolMacroBehaviour.UsingWorker")
        .unwrap_or_else(|| panic!("missing UsingWorker manifest: {manifests:#?}"));
    assert!(
        worker_manifest["functions"].as_array().is_some_and(|functions| {
            [
                "Elixir.ProtocolMacroBehaviour.UsingWorker.perform/1",
                "Elixir.ProtocolMacroBehaviour.UsingWorker.overridable_score/1",
                "Elixir.ProtocolMacroBehaviour.UsingWorker.macro_generated_score/1",
            ]
            .into_iter()
            .all(|key| functions.iter().any(|function| function["key"] == key))
        }) && worker_manifest["locations"].as_array().is_some_and(|locations| {
            locations.iter().any(|location| {
                location["trace_copy_path"] == "files/lib/protocol_macro_behaviour.ex"
                    && location["resolution"] == "source_map"
            })
        }),
        "UsingWorker manifest should expose behaviour, super, and macro-generated functions: {worker_manifest:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "mix.ct");
    assert!(
        reader.step_count() > 0,
        "CTFS reader should expose protocol/macro/behaviour steps"
    );
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    for path in [
        "lib/protocol_macro_behaviour.ex",
        "lib/protocol_macro_behaviour/macros.ex",
    ] {
        assert!(
            paths.iter().any(|observed| observed.ends_with(path)),
            "CTFS reader paths should include {path}: {paths:#?}"
        );
    }
    let function_names = reader_function_names(&reader);
    for expected in [
        "ProtocolMacroBehaviour.main/0",
        "ProtocolMacroBehaviour.protocol_matrix/0",
        "ProtocolMacroBehaviour.macro_matrix/1",
        "ProtocolMacroBehaviour.behaviour_matrix/1",
        "ProtocolMacroBehaviour.UsingWorker.perform/1",
        "ProtocolMacroBehaviour.UsingWorker.macro_generated_score/1",
        "ProtocolMacroBehaviour.Imported.imported_bonus/1",
    ] {
        assert!(
            function_names.iter().any(|name| name == expected),
            "CTFS reader should expose {expected}: {function_names:#?}"
        );
    }
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name == "ProtocolMacroBehaviour.UsingWorker.perform/1")
            && call_names.iter().any(|name| {
                name == "ProtocolMacroBehaviour.UsingWorker.macro_generated_score/1"
            })
            && call_names
                .iter()
                .any(|name| name == "ProtocolMacroBehaviour.Imported.imported_bonus/1"),
        "CTFS reader should expose protocol/macro/behaviour call records: {call_names:#?}"
    );

    let pairs = reader_value_pairs(&recorded.out_dir, "mix.ct");
    for (name, value) in [
        ("protocol_score", 199),
        ("macro_score", 220),
        ("behaviour_score", 75),
        ("attribute_score", 55),
        ("final_total", 549),
    ] {
        assert_reader_elixir_value(&pairs, name, value);
    }

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "mix.ct");
    assert_raw_elixir_value(&values, "final_total", "final integer total", |value| {
        matches!(value, ValueRecord::Int { i: 549, .. })
    });
}

#[test]
fn e2e_mix_records_umbrella_project() {
    let recorded = record_mix_task_eval(
        "m12-umbrella",
        "umbrella_app",
        "UmbrellaCore.main()",
        &["--include-app", "umbrella_core"],
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        String::from_utf8_lossy(&recorded.output.stdout).contains("umbrella-core:42"),
        "{}",
        output_text(&recorded.output)
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    assert!(
        manifests
            .iter()
            .any(|manifest| manifest["module"]["name"] == "Elixir.UmbrellaCore"),
        "selected umbrella app should produce manifests: {manifests:#?}"
    );
    assert!(
        !manifests
            .iter()
            .any(|manifest| manifest["module"]["name"] == "Elixir.UmbrellaExtra"),
        "unselected umbrella app should be filtered out: {manifests:#?}"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "Elixir.UmbrellaCore"
                && event["source_location"]["trace_copy_path"]
                    .as_str()
                    .is_some_and(|path| path.ends_with("umbrella_core/lib/umbrella_core.ex"))
        }),
        "selected umbrella app should produce trace events: {events:#?}"
    );
}

#[test]
fn e2e_elixir_macro_source_mapping_real_trace() {
    let recorded =
        record_mix_task_eval("m12-macro", "macro_locations", "MacroLocations.main()", &[]);
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        String::from_utf8_lossy(&recorded.output.stdout).contains("macro-ok:42"),
        "{}",
        output_text(&recorded.output)
    );

    let source_maps = source_map_jsons(&recorded.out_dir);
    assert!(
        source_maps.iter().any(|map| {
            map["source_language"] == "elixir"
                && map["macro_expansion_chain_policy"]
                    == "v1 records compiler-tracer macro event summaries but not full nested expansion chains"
                && map["mappings"].as_array().is_some_and(|mappings| {
                    mappings.iter().any(|mapping| {
                        mapping["reason"] == "debug_info_erlang_v1"
                            && mapping["original_line"].as_i64().is_some()
                    })
                })
        }),
        "real Mix source maps should record v1 macro-chain policy and sparse mappings: {source_maps:#?}"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "Elixir.MacroLocations")
        .unwrap_or_else(|| panic!("missing MacroLocations manifest: {manifests:#?}"));
    assert!(
        manifest["locations"].as_array().is_some_and(|locations| {
            locations.iter().any(|location| {
                location["resolution"] == "source_map"
                    && location["trace_copy_path"] == "files/lib/macro_locations.ex"
            }) && locations.iter().any(|location| {
                location["resolution"] == "unknown_generated_fallback"
            })
        }),
        "macro fixture should contain precise original mappings and generated fallbacks: {manifest:#?}"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "Elixir.MacroLocations"
                && event["function"] == "generated_answer"
                && event["source_location"]["resolution"] == "source_map"
        }),
        "runtime should record macro-generated function calls with source mapping: {events:#?}"
    );
}

#[test]
fn e2e_rebar3_profile_records_real_app() {
    let recorded = record_rebar3_profile("m13-rebar3-profile", "rebar3_app", "codetrace", &[]);
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        output_text(&recorded.output).contains("52"),
        "rebar3 shell should execute the real fixture main/0: {}",
        output_text(&recorded.output)
    );

    let build_dir = recorded.build_dir.as_ref().expect("rebar3 build dir");
    assert!(
        build_dir
            .join("instrumented/ebin/rebar3_app.beam")
            .is_file(),
        "provider mode should write isolated instrumented BEAMs under {}",
        build_dir.display()
    );
    let fixture_dir = repo_root().join("test-programs/erlang/rebar3_app");
    assert!(
        !fixture_dir
            .join("_build/default/lib/rebar3_app/ebin/rebar3_app.beam")
            .exists(),
        "codetrace profile must not mutate default Rebar3 build artifacts"
    );

    let meta = trace_meta(&recorded.out_dir);
    assert_eq!(meta["runtime_session"]["mode"], "beam");
    assert!(
        meta["runtime_session"]["injection_decision"]
            .as_str()
            .is_some_and(|decision| decision.contains("Rebar3 M13 injection")),
        "trace metadata should record Rebar3 runtime injection: {meta:#?}"
    );
    assert!(
        meta["sources"].as_array().is_some_and(|sources| {
            sources
                .iter()
                .any(|source| source["trace_copy_path"] == "files/src/rebar3_app.erl")
                && sources
                    .iter()
                    .any(|source| source["trace_copy_path"] == "files/lib/original_generated.ex")
        }),
        "trace bundle should include Rebar3 source files and generated-source originals: {meta:#?}"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    assert!(
        manifests
            .iter()
            .any(|manifest| manifest["module"]["name"] == "rebar3_app"),
        "missing rebar3_app manifest: {manifests:#?}"
    );
    assert!(
        !manifests
            .iter()
            .any(|manifest| manifest["module"]["name"] == "rebar3_ignored"),
        "module filters should exclude rebar3_ignored: {manifests:#?}"
    );
    let generated_manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "rebar3_generated")
        .unwrap_or_else(|| panic!("missing generated Rebar3 manifest: {manifests:#?}"));
    assert!(
        generated_manifest["locations"]
            .as_array()
            .is_some_and(|locations| {
                locations.iter().any(|location| {
                    location["resolution"] == "source_map"
                        && location["trace_copy_path"] == "files/lib/original_generated.ex"
                })
            }),
        "generated Erlang source map should resolve to original source: {generated_manifest:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "rebar3.ct");
    assert!(
        reader.step_count() > 0,
        "Rebar3 CTFS trace should contain steps"
    );
    assert!(
        reader_function_names(&reader)
            .iter()
            .any(|name| name.contains("rebar3_app:main/0")),
        "reader should expose real Rebar3 function names"
    );

    let filtered_out = record_rebar3_profile(
        "m13-rebar3-app-filter-mismatch",
        "rebar3_app",
        "codetrace",
        &["--exclude-app", "rebar3_app"],
    );
    assert_ne!(
        filtered_out.output.status.code(),
        Some(0),
        "app filters should be enforced by the real Rebar3 provider"
    );
    assert!(
        output_text(&filtered_out.output).contains("module_filter_mismatch"),
        "app filter mismatch should fail clearly: {}",
        output_text(&filtered_out.output)
    );
}

#[test]
fn e2e_rebar3_shell_runtime_trace() {
    let recorded = record_rebar3_profile("m13-rebar3-shell", "rebar3_shell", "codetrace", &[]);
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert!(
        output_text(&recorded.output).contains("42"),
        "rebar3 shell should run worker fixture: {}",
        output_text(&recorded.output)
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events
            .iter()
            .any(|event| event["event"] == "call" && event["module"] == "rebar3_shell"),
        "runtime should trace calls from the real Rebar3 shell: {events:#?}"
    );
    let messages = sidecar_message_events(&events);
    assert!(
        messages
            .iter()
            .any(|event| event["tag"] == "worker_result" && event["direction"] == "send"),
        "runtime should trace shell fixture send events: {messages:#?}"
    );
    assert!(
        messages
            .iter()
            .any(|event| event["tag"] == "worker_result" && event["direction"] == "receive"),
        "runtime should trace shell fixture receive events: {messages:#?}"
    );
    assert_reader_trace_log_contains(&recorded.out_dir, "rebar3.ct", &["worker_result"]);
}

#[test]
fn e2e_rebar3_parse_transform_compat() {
    let provider = record_rebar3_profile(
        "m13-rebar3-provider-baseline",
        "rebar3_app",
        "codetrace",
        &[
            "--include-module",
            "rebar3_app",
            "--include-module",
            "rebar3_helper",
        ],
    );
    assert_eq!(
        provider.output.status.code(),
        Some(0),
        "{}",
        output_text(&provider.output)
    );

    let compat = record_rebar3_profile(
        "m13-rebar3-parse-transform",
        "rebar3_app",
        "codetrace_parse_transform",
        &[
            "--profile",
            "codetrace_parse_transform",
            "--parse-transform",
            "--include-module",
            "rebar3_app",
            "--include-module",
            "rebar3_helper",
        ],
    );
    assert_eq!(
        compat.output.status.code(),
        Some(0),
        "{}",
        output_text(&compat.output)
    );

    let marker_dir = compat
        .build_dir
        .as_ref()
        .expect("compat build dir")
        .join("parse_transform_markers");
    assert!(
        marker_dir.join("rebar3_app.marker").is_file(),
        "parse-transform compatibility mode should compile through the real parse transform"
    );

    let provider_calls = runtime_sidecar_events(&provider.out_dir)
        .into_iter()
        .filter(|event| event["event"] == "call")
        .filter_map(|event| {
            Some(format!(
                "{}:{}",
                event["module"].as_str()?,
                event["function"].as_str()?
            ))
        })
        .collect::<std::collections::BTreeSet<_>>();
    let compat_calls = runtime_sidecar_events(&compat.out_dir)
        .into_iter()
        .filter(|event| event["event"] == "call")
        .filter_map(|event| {
            Some(format!(
                "{}:{}",
                event["module"].as_str()?,
                event["function"].as_str()?
            ))
        })
        .collect::<std::collections::BTreeSet<_>>();

    for expected in ["rebar3_app:main", "rebar3_helper:add"] {
        assert!(
            provider_calls.contains(expected) && compat_calls.contains(expected),
            "parse-transform mode should preserve provider-supported call events; provider={provider_calls:#?} compat={compat_calls:#?}"
        );
    }

    let reader = open_named_trace(&compat.out_dir, "rebar3.ct");
    assert!(
        reader.call_count() > 0,
        "parse-transform compatibility trace should be readable through the real CTFS reader"
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
fn e2e_clause_entry_bindings_match_golden() {
    let recorded = record_erlang_canonical_function("m9-clause-entry-bindings", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(String::from_utf8_lossy(&recorded.output.stdout), "94\n");

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("A", 10),
        ("B", 32),
        ("SumVal", 42),
        ("Doubled", 84),
        ("FinalResult", 94),
        ("Result", 94),
    ] {
        assert_sidecar_binding(&binds, name, value);
    }

    let pairs = reader_value_pairs(&recorded.out_dir, "erl.ct");
    for (name, value) in [
        ("A", 10),
        ("B", 32),
        ("SumVal", 42),
        ("Doubled", 84),
        ("FinalResult", 94),
        ("Result", 94),
    ] {
        assert_reader_value(&pairs, name, value);
    }

    let drops = sidecar_drop_events(&recorded.out_dir);
    assert!(
        drops.iter().any(|event| {
            event["variables"].as_array().is_some_and(|variables| {
                variables
                    .iter()
                    .any(|variable| variable["name"] == "FinalResult")
            })
        }) && drops.iter().any(|event| {
            event["variables"].as_array().is_some_and(|variables| {
                variables
                    .iter()
                    .any(|variable| variable["name"] == "Result")
            })
        }),
        "frame exits should drop compute/0 and main/0 variables: {drops:#?}"
    );

    let raw_drops = raw_ctfs_drop_variable_names(&recorded.out_dir, "erl.ct");
    assert_raw_ctfs_drop(&raw_drops, "FinalResult");
    assert_raw_ctfs_drop(&raw_drops, "Result");
}

#[test]
fn e2e_value_encoder_real_term_matrix() {
    let recorded = record_erlang_value_matrix_function("m10-value-matrix", "main");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "value-matrix-ok\n"
    );

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "erl.ct");
    let types = raw_ctfs_low_level_types(&recorded.out_dir, "erl.ct");

    assert!(matches!(
        find_named_value(&values, "SmallInt"),
        ValueRecord::Int { i: 42, .. }
    ));
    assert!(matches!(
        find_named_value(&values, "BigInt"),
        ValueRecord::BigInt { negative: false, b, .. } if !b.is_empty()
    ));
    assert!(matches!(
        find_named_value(&values, "Float"),
        ValueRecord::Float { f, .. } if (*f - 3.25).abs() < f64::EPSILON
    ));
    assert!(matches!(
        find_named_value(&values, "TrueValue"),
        ValueRecord::Bool { b: true, .. }
    ));
    assert!(matches!(
        find_named_value(&values, "FalseValue"),
        ValueRecord::Bool { b: false, .. }
    ));
    assert!(matches!(
        find_named_value(&values, "AtomValue"),
        ValueRecord::Raw { r, .. } if r == "sample_atom"
    ));
    assert!(matches!(
        find_named_value(&values, "TupleValue"),
        ValueRecord::Tuple { elements, .. } if elements.len() == 3
    ));
    assert!(matches!(
        find_named_value(&values, "EmptyList"),
        ValueRecord::Sequence { elements, .. } if elements.is_empty()
    ));
    assert!(matches!(
        find_named_value(&values, "ListValue"),
        ValueRecord::Sequence { elements, .. } if elements.len() == 3
    ));
    assert!(matches!(
        find_named_value(&values, "StringBinary"),
        ValueRecord::String { text, .. } if text == "hello utf8"
    ));
    assert!(matches!(
        find_named_value(&values, "RawBinary"),
        ValueRecord::Raw { r, .. } if r.starts_with("0x00FF1041")
    ));
    assert!(matches!(
        find_named_value(&values, "InvalidUtf8Binary"),
        ValueRecord::Raw { r, .. } if r.starts_with("0xFFFEFD")
    ));
    assert!(matches!(
        find_named_value(&values, "SimpleMap"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "ComplexMap"),
        ValueRecord::Raw { r, .. } if r.contains("complex")
    ));
    assert!(matches!(
        find_named_value(&values, "RecordValue"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 3
    ));
    assert!(matches!(
        find_named_value(&values, "PidValue"),
        ValueRecord::Raw { .. }
    ));
    assert!(matches!(
        find_named_value(&values, "RefValue"),
        ValueRecord::Raw { .. }
    ));
    assert!(matches!(
        find_named_value(&values, "PortValue"),
        ValueRecord::Raw { .. }
    ));
    assert!(matches!(
        find_named_value(&values, "FunValue"),
        ValueRecord::Raw { .. }
    ));

    assert_value_type(&values, &types, "SmallInt", TypeKind::Int, "integer");
    assert_value_type(&values, &types, "StringBinary", TypeKind::String, "binary");
    assert_value_type(&values, &types, "SimpleMap", TypeKind::Struct, "map");
    assert_value_type(
        &values,
        &types,
        "RecordValue",
        TypeKind::Struct,
        "record:person",
    );
    assert_value_type(&values, &types, "PidValue", TypeKind::Ref, "pid");
    assert_value_type(&values, &types, "RefValue", TypeKind::Ref, "reference");
    assert_value_type(&values, &types, "PortValue", TypeKind::Ref, "port");
    assert_value_type(&values, &types, "FunValue", TypeKind::FunctionKind, "fun");
}

#[test]
fn e2e_value_truncation_limits_real_trace() {
    let recorded = record_erlang_value_matrix_function_with_env(
        "m10-truncation",
        "truncation",
        &[
            ("CODETRACER_ELIXIR_VALUE_MAX_DEPTH", "2"),
            ("CODETRACER_ELIXIR_VALUE_MAX_SEQUENCE_ITEMS", "3"),
            ("CODETRACER_ELIXIR_VALUE_MAX_BINARY_BYTES", "4"),
            ("CODETRACER_ELIXIR_VALUE_MAX_MAP_PAIRS", "2"),
            ("CODETRACER_ELIXIR_VALUE_MAX_STRING_BYTES", "5"),
        ],
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "truncation-ok\n"
    );

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "erl.ct");
    let long_list = find_named_value(&values, "LongList");
    assert!(matches!(
        long_list,
        ValueRecord::Sequence { elements, .. }
            if elements.len() == 4
                && matches!(elements.last(), Some(ValueRecord::Raw { r, .. }) if r == "[truncated]")
    ));
    assert!(matches!(
        find_named_value(&values, "LongString"),
        ValueRecord::String { text, .. } if text == "aaaaa..."
    ));
    assert!(matches!(
        find_named_value(&values, "LongRawBinary"),
        ValueRecord::Raw { r, .. } if r == "0x00FF1041..."
    ));
    assert!(matches!(
        find_named_value(&values, "LargeMap"),
        ValueRecord::Struct { field_values, .. }
            if field_values.iter().any(|value| matches!(value, ValueRecord::Raw { r, .. } if r == "[truncated]"))
    ));
    assert!(matches!(
        find_named_value(&values, "LargeComplexMap"),
        ValueRecord::Raw { r, .. } if r.len() <= 7 && r.ends_with("...")
    ));
    assert!(format!("{:#?}", find_named_value(&values, "Deep")).contains("[truncated]"));
}

#[test]
fn e2e_elixir_nil_erlang_empty_list_distinction() {
    let elixir_recorded = record_elixir_fixture_expression(
        "m10-elixir-nil",
        "value_matrix",
        "ValueMatrix.identity(nil); ValueMatrix.identity([]); IO.puts(\"nil-list-ok\")",
    );
    assert_eq!(
        elixir_recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&elixir_recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&elixir_recorded.output.stdout),
        "nil-list-ok\n"
    );
    let elixir_values = raw_ctfs_low_level_values(&elixir_recorded.out_dir, "mix.ct");
    let arg0_values = elixir_values
        .iter()
        .filter(|(name, _)| name == "_arg0")
        .map(|(_, value)| value)
        .collect::<Vec<_>>();
    assert!(
        arg0_values
            .iter()
            .any(|value| matches!(value, ValueRecord::None { .. })),
        "Elixir nil should be encoded as None through raw CTFS values: {arg0_values:#?}"
    );
    assert!(
        arg0_values.iter().any(
            |value| matches!(value, ValueRecord::Sequence { elements, .. } if elements.is_empty())
        ),
        "Elixir [] should remain an empty list through raw CTFS values: {arg0_values:#?}"
    );

    let erlang_recorded = record_erlang_value_matrix_function("m10-erlang-empty-list", "main");
    assert_eq!(
        erlang_recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&erlang_recorded.output)
    );
    let erlang_values = raw_ctfs_low_level_values(&erlang_recorded.out_dir, "erl.ct");
    let list_value = find_named_value(&erlang_values, "EmptyList");
    assert!(
        matches!(list_value, ValueRecord::Sequence { elements, .. } if elements.is_empty()),
        "Erlang [] should remain an empty list sequence, not None: {list_value:#?}"
    );
}

#[test]
fn e2e_pattern_clause_selection_bindings() {
    let recorded = record_erlang_branch_function("m9-pattern-clauses", "main");
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

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("Value", 1),
        ("N", 7),
        ("Quotient", 5),
        ("C", 11),
        ("X", 4),
        ("E", 13),
        ("F", 7),
    ] {
        assert_sidecar_binding(&binds, name, value);
    }
    assert!(
        !binds.iter().any(|event| event["name"] == "_"),
        "wildcard clauses must not create source-visible variable bindings: {binds:#?}"
    );

    let pairs = reader_value_pairs(&recorded.out_dir, "erl.ct");
    for (name, value) in [("N", 7), ("Quotient", 5), ("C", 11), ("X", 4)] {
        assert_reader_value(&pairs, name, value);
    }
}

#[test]
fn e2e_erlang_syntax_matrix_constructs() {
    let recorded = record_erlang_fixture_function(
        "m13-erlang-syntax-matrix",
        "syntax_matrix",
        "syntax_matrix",
        "main",
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "syntax-matrix-ok:658\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "syntax_matrix"
                && event["function"] == "main"
                && event["arity"] == 0
        }),
        "runtime sidecar should contain the syntax_matrix:main/0 call: {events:#?}"
    );

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("Head", 9),
        ("ListScore", 13),
        ("MapLeft", 21),
        ("MapRight", 22),
        ("MapTotal", 43),
        ("ByteA", 255),
        ("ByteB", 22),
        ("Wide", 43),
        ("CompareScore", 3),
        ("BitScore", 38),
        ("BoolScore", 3),
        ("ImportedTotal", 43),
        ("Applied", 44),
        ("LocalFunResult", 40),
        ("RemoteFunResult", 4),
        ("ClosureResult", 15),
        ("MultiResult", 26),
        ("BeginResult", 44),
        ("MaybeScore", 17),
        ("MaybeElse", 5),
        ("FinalTotal", 658),
    ] {
        assert_sidecar_binding(&binds, name, value);
    }

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    assert!(
        reader.step_count() > 0,
        "reader should expose syntax-matrix steps"
    );
    let function_names = reader_function_names(&reader);
    assert!(
        function_names
            .iter()
            .any(|name| name == "syntax_matrix:main/0"),
        "CTFS reader should expose syntax_matrix:main/0: {function_names:#?}"
    );

    let pairs = reader_value_pairs(&recorded.out_dir, "erl.ct");
    for (name, value) in [
        ("BitScore", 38),
        ("BoolScore", 3),
        ("MaybeScore", 17),
        ("FinalTotal", 658),
    ] {
        assert_reader_value(&pairs, name, value);
    }

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "erl.ct");
    assert!(matches!(
        find_named_value(&values, "Diff"),
        ValueRecord::Sequence { elements, .. } if elements.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "UpdatedMap"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 3
    ));
    assert!(matches!(
        find_named_value(&values, "Packed"),
        ValueRecord::Raw { r, .. } if r.starts_with("0xFF16002B")
    ));
    assert!(matches!(
        find_named_value(&values, "FinalTotal"),
        ValueRecord::Int { i: 658, .. }
    ));
}

#[test]
fn e2e_erlang_reference_edge_constructs() {
    let recorded = record_erlang_fixture_function(
        "m13-erlang-reference-edges",
        "reference_edges",
        "reference_edges",
        "main",
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "reference-edges-ok:721\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "reference_edges"
                && event["function"] == "main"
                && event["arity"] == 0
                && event["source_location"]["trace_copy_path"] == "files/src/reference_edges.erl"
        }),
        "runtime sidecar should contain reference_edges:main/0 with source metadata: {events:#?}"
    );

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("Id", 7),
        ("Matched", 41),
        ("Static", 2),
        ("ExtraValue", 5),
        ("MapScore", 51),
        ("PayloadSize", 9),
        ("BitsSize", 8),
        ("SegmentSize", 9),
        ("Little", 513),
        ("Signed", -3),
        ("Tiny", 5),
        ("PrefixScore", 66),
        ("Inner", 23),
        ("OrderedValue", 19),
        ("PatternScore", 46),
        ("FinalTotal", 721),
    ] {
        assert_sidecar_binding(&binds, name, value);
    }
    assert!(
        sidecar_binding_values(&binds, "CreatedMap")
            .iter()
            .any(|value| {
                value["kind"] == "raw"
                    && value["lang_type"] == "map"
                    && value["value"].as_str().is_some_and(|raw| {
                        raw.contains("static => 2")
                            && raw.contains("{<<109,101,116,114,105,99>>,7} => 40")
                    })
            }),
        "dynamic-key map creation should be sidecar-visible: {binds:#?}"
    );
    assert!(
        sidecar_binding_values(&binds, "UpdatedMap")
            .iter()
            .any(|value| {
                value["kind"] == "raw"
                    && value["lang_type"] == "map"
                    && value["value"].as_str().is_some_and(|raw| {
                        raw.contains("{extra,7} => 5")
                            && raw.contains("{<<109,101,116,114,105,99>>,7} => 41")
                    })
            }),
        "dynamic-key map update should be sidecar-visible: {binds:#?}"
    );
    assert!(
        sidecar_binding_values(&binds, "TypedBinary")
            .iter()
            .any(|value| {
                value["kind"] == "raw"
                    && value["lang_type"] == "binary"
                    && value["value"]
                        .as_str()
                        .is_some_and(|raw| raw.starts_with("0x096D6574616372616674"))
            }),
        "typed dynamic binary should be sidecar-visible: {binds:#?}"
    );
    assert!(
        sidecar_binding_values(&binds, "Path")
            .iter()
            .any(|value| value["kind"] == "string" && value["value"] == "/edge"),
        "string-prefix binary match should expose Path as a binary string: {binds:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    assert!(
        reader.step_count() > 0,
        "reader should expose reference-edge steps"
    );
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name == "reference_edges:main/0"),
        "CTFS reader should expose reference_edges:main/0 call records: {call_names:#?}"
    );

    let pairs = reader_value_pairs(&recorded.out_dir, "erl.ct");
    for (name, value) in [
        ("MapScore", 51),
        ("BinaryScore", 558),
        ("PrefixScore", 66),
        ("PatternScore", 46),
        ("FinalTotal", 721),
    ] {
        assert_reader_value(&pairs, name, value);
    }

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "erl.ct");
    assert!(matches!(
        find_named_value(&values, "UpdatedMap"),
        ValueRecord::Raw { r, .. }
            if r.contains("{extra,7} => 5")
                && r.contains("{<<109,101,116,114,105,99>>,7} => 41")
    ));
    assert!(matches!(
        find_named_value(&values, "TypedBinary"),
        ValueRecord::Raw { r, .. } if r.starts_with("0x096D6574616372616674")
    ));
    assert!(matches!(
        find_named_value(&values, "PathAndVersion"),
        ValueRecord::String { text, .. } if text == "/edge HTTP/1.1"
    ));
    assert!(matches!(
        find_named_value(&values, "Shared"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "FinalTotal"),
        ValueRecord::Int { i: 721, .. }
    ));
}

#[test]
fn e2e_erlang_comprehension_matrix_constructs() {
    let recorded = record_erlang_fixture_function(
        "m13-erlang-comprehension-matrix",
        "comprehension_matrix",
        "comprehension_matrix",
        "main",
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "comprehension-matrix-ok:656\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "comprehension_matrix"
                && event["function"] == "main"
                && event["arity"] == 0
                && event["source_location"]["trace_copy_path"]
                    == "files/src/comprehension_matrix.erl"
        }),
        "runtime sidecar should contain comprehension_matrix:main/0 with source metadata: {events:#?}"
    );

    let binds = sidecar_variable_binds(&recorded.out_dir);
    for (name, value) in [
        ("ListScore", 120),
        ("PairScore", 68),
        ("BinaryFilterScore", 325),
        ("BinaryListScore", 18),
        ("MapGenScore", 82),
        ("MapListScore", 19),
        ("CrossMapScore", 24),
        ("FinalTotal", 656),
    ] {
        assert_sidecar_binding(&binds, name, value);
    }
    assert_sidecar_list_binding(&binds, "ListSquares", 4);
    assert_sidecar_list_binding(&binds, "NestedPairs", 4);
    assert_sidecar_map_struct_binding(&binds, "MapFiltered", 2);
    assert_sidecar_map_struct_binding(&binds, "MapFromPairs", 2);
    assert!(
        sidecar_binding_values(&binds, "BinaryFiltered")
            .iter()
            .any(|value| {
                value["kind"] == "raw"
                    && value["lang_type"] == "binary"
                    && value["value"] == "0x00FF4105"
            }),
        "binary comprehension result should be sidecar-visible: {binds:#?}"
    );

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    assert!(
        reader.step_count() > 0,
        "reader should expose comprehension-matrix steps"
    );
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name == "comprehension_matrix:main/0"),
        "CTFS reader should expose comprehension_matrix:main/0 call records: {call_names:#?}"
    );

    let pairs = reader_value_pairs(&recorded.out_dir, "erl.ct");
    for (name, value) in [
        ("ListScore", 120),
        ("BinaryFilterScore", 325),
        ("MapGenScore", 82),
        ("FinalTotal", 656),
    ] {
        assert_reader_value(&pairs, name, value);
    }

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "erl.ct");
    assert!(matches!(
        find_named_value(&values, "ListSquares"),
        ValueRecord::Sequence { elements, .. } if elements.len() == 4
    ));
    assert!(matches!(
        find_named_value(&values, "NestedPairs"),
        ValueRecord::Sequence { elements, .. } if elements.len() == 4
    ));
    assert!(matches!(
        find_named_value(&values, "BinaryFiltered"),
        ValueRecord::Raw { r, .. } if r == "0x00FF4105"
    ));
    assert!(matches!(
        find_named_value(&values, "MapFiltered"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "MapFromPairs"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "FinalTotal"),
        ValueRecord::Int { i: 656, .. }
    ));
}

#[test]
fn e2e_erlang_exceptions_matrix_constructs() {
    let recorded = record_erlang_fixture_function(
        "m13-erlang-exceptions-matrix",
        "exceptions_matrix",
        "exceptions_matrix",
        "main",
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "exceptions-matrix-ok:67\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "exceptions_matrix"
                && event["function"] == "main"
                && event["arity"] == 0
                && event["source_location"]["trace_copy_path"] == "files/src/exceptions_matrix.erl"
        }),
        "runtime sidecar should contain exceptions_matrix:main/0 with source metadata: {events:#?}"
    );
    for (function, class, reason) in [
        ("thrower", "throw", "{thrown,21}"),
        ("errorer", "error", "{bad_input,4}"),
        ("exiter", "exit", "{exit_reason,9}"),
    ] {
        assert!(
            events.iter().any(|event| {
                event["event"] == "exception_from"
                    && event["module"] == "exceptions_matrix"
                    && event["function"] == function
                    && event["arity"] == 1
                    && event["class"] == class
                    && event["reason_repr"]
                        .as_str()
                        .is_some_and(|text| text.contains(reason))
            }),
            "sidecar should expose exception_from for {function}/1 {class}:{reason}: {events:#?}"
        );
    }

    let binds = sidecar_variable_binds(&recorded.out_dir);
    assert_sidecar_record_binding(&binds, "CatchThrow", "catch_expr_throw", 2, None);
    assert_sidecar_record_binding(&binds, "CatchExit", "EXIT", 2, Some("catch_expr_exit"));
    assert_sidecar_record_binding(&binds, "TryThrowResult", "caught_throw", 2, None);
    assert_sidecar_record_binding(&binds, "TryErrorResult", "caught_error", 2, None);
    assert_sidecar_record_binding(&binds, "TryExitResult", "caught_exit", 2, None);
    assert_sidecar_record_binding(&binds, "TrySuccess", "success", 2, None);
    assert_sidecar_binding(&binds, "AfterScore", 4);
    assert_sidecar_binding(&binds, "FinalTotal", 67);

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    assert!(
        reader.step_count() > 0,
        "reader should expose exceptions-matrix steps"
    );
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name == "exceptions_matrix:succeed/1")
            && call_names
                .iter()
                .any(|name| name == "exceptions_matrix:after_score/1"),
        "CTFS reader should expose real call records for successful and after-observed paths: {call_names:#?}"
    );

    let event_payloads = (0..reader.event_count())
        .map(|index| {
            decode_reader_event_content(&reader.event_json(index).expect("read event json"))
        })
        .collect::<Vec<_>>();
    for reason in ["{thrown,21}", "{bad_input,4}", "{exit_reason,9}"] {
        assert!(
            event_payloads.iter().any(|payload| {
                payload.contains("codetracer.elixir.exception_from.v1")
                    && payload.contains("exceptions_matrix")
                    && payload.contains(reason)
            }),
            "CTFS reader should expose exception_from event for {reason}: {event_payloads:#?}"
        );
    }

    let pairs = reader_value_pairs(&recorded.out_dir, "erl.ct");
    assert_reader_value(&pairs, "AfterScore", 4);
    assert_reader_value(&pairs, "FinalTotal", 67);

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "erl.ct");
    assert!(matches!(
        find_named_value(&values, "CatchThrow"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "CatchExit"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "TryThrowResult"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "TryErrorResult"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "TryExitResult"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "TrySuccess"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 2
    ));
    assert!(matches!(
        find_named_value(&values, "FinalTotal"),
        ValueRecord::Int { i: 67, .. }
    ));
}

#[test]
fn e2e_erlang_records_matrix_constructs() {
    let recorded = record_erlang_fixture_function(
        "m13-erlang-records-matrix",
        "records_matrix",
        "records_matrix",
        "main",
    );
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(
        String::from_utf8_lossy(&recorded.output.stdout),
        "records-matrix-ok:4431\n"
    );

    let events = runtime_sidecar_events(&recorded.out_dir);
    assert!(
        events.iter().any(|event| {
            event["event"] == "call"
                && event["module"] == "records_matrix"
                && event["function"] == "main"
                && event["arity"] == 0
                && event["source_location"]["trace_copy_path"] == "files/src/records_matrix.erl"
        }),
        "runtime sidecar should contain records_matrix:main/0 with source metadata: {events:#?}"
    );

    let binds = sidecar_variable_binds(&recorded.out_dir);
    assert_sidecar_record_binding(&binds, "DefaultAddress", "address", 3, None);
    assert_sidecar_record_binding(&binds, "DefaultProfile", "profile", 5, Some("address"));
    assert_sidecar_record_binding(&binds, "AddressUpdate", "address", 3, None);
    assert_sidecar_record_binding(&binds, "UpdatedProfile", "profile", 5, Some("address"));
    assert_sidecar_record_binding(&binds, "ProfileAddress", "address", 3, None);
    assert_sidecar_record_binding(&binds, "Envelope", "envelope", 3, Some("profile"));
    assert_sidecar_record_binding(&binds, "NestedProfile", "profile", 5, Some("address"));
    assert_sidecar_record_binding(&binds, "NestedAddress", "address", 3, None);
    for (name, value) in [
        ("ProfileAge", 44),
        ("ProfileZip", 4242),
        ("MatchedZip", 4242),
        ("GuardScore", 23),
        ("PatternScore", 86),
        ("NestedZip", 4242),
        ("ProfileSize", 5),
        ("AddressSize", 3),
        ("EnvelopeSize", 3),
        ("FieldsScore", 19),
        ("Total", 4431),
    ] {
        assert_sidecar_binding(&binds, name, value);
    }
    assert_sidecar_list_binding(&binds, "ProfileFields", 4);
    assert_sidecar_list_binding(&binds, "AddressFields", 2);
    assert_sidecar_list_binding(&binds, "EnvelopeFields", 2);
    assert!(
        sidecar_binding_values(&binds, "ModuleMacro")
            .iter()
            .any(|value| value["kind"] == "atom" && value["value"] == "records_matrix")
            && sidecar_binding_values(&binds, "LineMacro")
                .iter()
                .any(|value| reader_value_int(value).is_some_and(|line| line > 0))
            && sidecar_binding_values(&binds, "IncludeTag")
                .iter()
                .any(|value| {
                    value["kind"] == "atom" && value["value"] == "records_matrix_include_marker"
                }),
        "macro-expanded bindings should be sidecar-visible: {binds:#?}"
    );

    let values = raw_ctfs_low_level_values(&recorded.out_dir, "erl.ct");
    let types = raw_ctfs_low_level_types(&recorded.out_dir, "erl.ct");
    assert!(matches!(
        find_named_value(&values, "DefaultAddress"),
        ValueRecord::Struct { field_values, .. } if field_values.len() == 3
    ));
    assert!(matches!(
        find_named_value(&values, "UpdatedProfile"),
        ValueRecord::Struct { field_values, .. }
            if field_values.len() == 5
                && field_values
                    .iter()
                    .any(|value| matches!(value, ValueRecord::Struct { field_values, .. } if field_values.len() == 3))
    ));
    assert!(matches!(
        find_named_value(&values, "Envelope"),
        ValueRecord::Struct { field_values, .. }
            if field_values.len() == 3
                && field_values
                    .iter()
                    .any(|value| matches!(value, ValueRecord::Struct { field_values, .. } if field_values.len() == 5))
    ));
    assert!(matches!(
        find_named_value(&values, "ProfileFields"),
        ValueRecord::Sequence { elements, .. } if elements.len() == 4
    ));
    assert!(matches!(
        find_named_value(&values, "ProfileSize"),
        ValueRecord::Int { i: 5, .. }
    ));
    assert!(matches!(
        find_named_value(&values, "ModuleMacro"),
        ValueRecord::Raw { r, .. } if r == "records_matrix"
    ));
    assert!(matches!(
        find_named_value(&values, "IncludeTag"),
        ValueRecord::Raw { r, .. } if r == "records_matrix_include_marker"
    ));
    assert!(matches!(
        find_named_value(&values, "LineMacro"),
        ValueRecord::Int { i, .. } if *i > 0
    ));
    assert_value_type(
        &values,
        &types,
        "UpdatedProfile",
        TypeKind::Struct,
        "record:profile",
    );
    assert_value_type(
        &values,
        &types,
        "ProfileAddress",
        TypeKind::Struct,
        "record:address",
    );
    assert_value_type(
        &values,
        &types,
        "Envelope",
        TypeKind::Struct,
        "record:envelope",
    );

    let meta = trace_meta(&recorded.out_dir);
    assert!(
        meta["sources"].as_array().is_some_and(|sources| {
            sources.iter().any(|source| {
                source["trace_copy_path"] == "files/src/records_matrix.erl"
                    && source["build_path"]
                        .as_str()
                        .is_some_and(|path| path.ends_with("src/records_matrix.erl"))
            })
        }),
        "trace metadata should list copied records_matrix source: {meta:#?}"
    );
    assert!(
        recorded
            .out_dir
            .join("files/src/records_matrix.erl")
            .is_file(),
        "trace bundle should contain src/records_matrix.erl"
    );

    let manifests = manifest_jsons(&recorded.out_dir);
    let manifest = manifests
        .iter()
        .find(|manifest| manifest["module"]["name"] == "records_matrix")
        .unwrap_or_else(|| panic!("missing records_matrix manifest: {manifests:#?}"));
    assert_eq!(
        manifest["module"]["trace_copy_path"],
        "files/src/records_matrix.erl"
    );
    assert!(
        manifest["functions"].as_array().is_some_and(|functions| {
            [
                "records_matrix.main/0",
                "records_matrix.classify/1",
                "records_matrix.pattern_score/1",
            ]
            .into_iter()
            .all(|key| functions.iter().any(|function| function["key"] == key))
        }) && manifest["locations"].as_array().is_some_and(|locations| {
            locations.iter().any(|location| {
                location["trace_copy_path"] == "files/src/records_matrix.erl"
                    && location["resolution"] == "erl_anno"
            })
        }),
        "records_matrix manifest should reference source functions and locations: {manifest:#?}"
    );

    let dump = transformed_dump_text(&recorded.out_dir, "src_records_matrix.erl.transformed.erl");
    for fragment in [
        "-record(address",
        "-record(profile",
        "-record(envelope",
        "records_matrix_include_marker",
    ] {
        assert!(
            dump.contains(fragment),
            "transformed forms should expose include-expanded record/macro fragment {fragment:?}: {dump}"
        );
    }

    let reader = open_named_trace(&recorded.out_dir, "erl.ct");
    assert!(
        reader_function_names(&reader)
            .iter()
            .any(|name| name == "records_matrix:main/0"),
        "CTFS reader should expose records_matrix:main/0"
    );
    let paths = (0..reader.path_count())
        .map(|id| reader.path(id).expect("reader path"))
        .collect::<Vec<_>>();
    assert!(
        paths
            .iter()
            .any(|path| path.ends_with("src/records_matrix.erl")),
        "CTFS reader paths should include records_matrix source: {paths:#?}"
    );
}

#[test]
fn e2e_variable_lifecycle_across_recursion() {
    let recorded = record_erlang_tail_function("m9-recursion-lifecycle", "small");
    assert_eq!(
        recorded.output.status.code(),
        Some(0),
        "{}",
        output_text(&recorded.output)
    );
    assert_eq!(String::from_utf8_lossy(&recorded.output.stdout), "3\n");

    let binds = sidecar_variable_binds(&recorded.out_dir);
    let n_binds = binds
        .iter()
        .filter(|event| event["name"] == "N")
        .collect::<Vec<_>>();
    let n_frame_ids = n_binds
        .iter()
        .filter_map(|event| event["frame_id"].as_u64())
        .collect::<std::collections::HashSet<_>>();
    let n_runtime_ids = n_binds
        .iter()
        .filter_map(|event| event["runtime_variable_id"].as_u64())
        .collect::<std::collections::HashSet<_>>();
    assert_eq!(
        n_binds.len(),
        3,
        "N should bind once per recursive non-base frame: {binds:#?}"
    );
    assert_eq!(
        n_frame_ids.len(),
        3,
        "N bindings should be frame-local: {n_binds:#?}"
    );
    assert_eq!(
        n_runtime_ids.len(),
        3,
        "runtime variable ids should be frame-local: {n_binds:#?}"
    );

    let drops = sidecar_drop_events(&recorded.out_dir);
    for bind in n_binds {
        let runtime_id = bind["runtime_variable_id"]
            .as_u64()
            .expect("N runtime variable id");
        assert!(
            drops.iter().any(|drop| {
                drop["variables"].as_array().is_some_and(|variables| {
                    variables
                        .iter()
                        .any(|variable| variable["runtime_variable_id"].as_u64() == Some(runtime_id))
                })
            }),
            "recursive runtime variable id {runtime_id} should be dropped on frame exit: {drops:#?}"
        );
    }

    let raw_drops = raw_ctfs_drop_variable_names(&recorded.out_dir, "erl.ct");
    let raw_n_drop_count = raw_drops
        .iter()
        .filter(|variables| variables.iter().any(|variable| variable == "N"))
        .count();
    assert_eq!(
        raw_n_drop_count, 3,
        "raw CTFS should expose one real DropVariables event for each recursive N frame: {raw_drops:#?}"
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
fn e2e_cli_compile_records_real_erlang_project() {
    let tmp = temp_dir("m11-compile-record");
    let fixture_dir = repo_root().join("test-programs/erlang/multi_module");
    let build_dir = tmp.join("standalone-build");
    let out_dir = tmp.join("trace");

    let compile = clean_recorder_command()
        .args([
            "compile",
            "--build-dir",
            build_dir.to_str().unwrap(),
            "--source-dir",
            fixture_dir.to_str().unwrap(),
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("compile standalone Erlang fixture");
    assert_eq!(compile.status.code(), Some(0), "{}", output_text(&compile));
    assert!(build_dir.join("standalone_build.json").is_file());
    assert!(build_dir
        .join("instrumented/ebin/standalone_main.beam")
        .is_file());
    assert!(build_dir
        .join("instrumented/ebin/standalone_helper.beam")
        .is_file());

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--build-dir",
            build_dir.to_str().unwrap(),
            "--root-mfa",
            "standalone_main:main/0",
            "--",
            "erl",
            "-noshell",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("record standalone Erlang fixture");
    assert_eq!(output.status.code(), Some(0), "{}", output_text(&output));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "m11-multi:42\n");

    let reader = open_named_trace(&out_dir, "erl.ct");
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name.contains("standalone_main:main/0"))
            && call_names
                .iter()
                .any(|name| name.contains("standalone_helper:bonus/1")),
        "reader should expose calls from both real modules: {call_names:#?}"
    );
    let mut raw_reader = CtfsReader::open(&out_dir.join("erl.ct")).expect("open raw CTFS trace");
    let raw_steps = raw_reader
        .read_file("steps.dat")
        .expect("read raw steps.dat");
    assert!(
        !raw_steps.is_empty(),
        "raw CTFS should contain instrumented steps"
    );

    let generated_fixture = repo_root().join("test-programs/erlang/generated_source_map");
    let generated_build_dir = tmp.join("generated-build");
    let generated_compile = clean_recorder_command()
        .args([
            "compile",
            "--build-dir",
            generated_build_dir.to_str().unwrap(),
            "--source-dir",
            generated_fixture.to_str().unwrap(),
            "--source-map",
            generated_fixture
                .join("source_maps/generated_bridge.json")
                .to_str()
                .unwrap(),
        ])
        .current_dir(&generated_fixture)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("compile generated Erlang source-map fixture");
    assert_eq!(
        generated_compile.status.code(),
        Some(0),
        "{}",
        output_text(&generated_compile)
    );
    assert!(
        generated_build_dir
            .join("recorder_metadata/source_maps/001-src_generated_bridge.erl.json")
            .is_file(),
        "explicit source map should be copied into standalone build metadata"
    );
    let generated_manifests = manifest_jsons(&generated_build_dir);
    assert!(
        generated_manifests.iter().any(|manifest| {
            manifest["locations"].as_array().is_some_and(|locations| {
                locations
                    .iter()
                    .any(|location| location["resolution"] == "source_map")
            })
        }),
        "generated Erlang compile should preserve source-map-resolved manifest locations"
    );

    let auto_tmp = tmp.join("auto-record");
    fs::create_dir_all(&auto_tmp).expect("create auto-record cwd");
    let auto_out_dir = auto_tmp.join("trace");
    let auto_output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            auto_out_dir.to_str().unwrap(),
            "--source-dir",
            fixture_dir.to_str().unwrap(),
            "--root-mfa",
            "standalone_main:main/0",
            "--",
            "erl",
            "-noshell",
        ])
        .current_dir(&auto_tmp)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("record standalone Erlang fixture with default build dir");
    assert_eq!(
        auto_output.status.code(),
        Some(0),
        "{}",
        output_text(&auto_output)
    );
    assert_eq!(
        String::from_utf8_lossy(&auto_output.stdout),
        "m11-multi:42\n"
    );
    assert!(auto_tmp
        .join("_codetracer/elixir-recorder/standalone/standalone_build.json")
        .is_file());
    let auto_reader = open_named_trace(&auto_out_dir, "erl.ct");
    let auto_call_names = reader_call_function_names(&auto_reader);
    assert!(
        auto_call_names
            .iter()
            .any(|name| name.contains("standalone_helper:bonus/1")),
        "record --source-dir should compile and prepend the default instrumented build: {auto_call_names:#?}"
    );
}

#[test]
fn e2e_cli_instrument_build_dir_isolated() {
    let tmp = temp_dir("m11-instrument-isolated");
    let fixture_dir = repo_root().join("test-programs/erlang/multi_module");
    let source_dir = fixture_dir.join("src");
    let normal_ebin = tmp.join("normal-ebin");
    let build_dir = tmp.join("instrumented-build");
    compile_erlang_sources(&source_dir, &normal_ebin);
    let before = fs::read(normal_ebin.join("standalone_main.beam")).expect("read original beam");

    let output = clean_recorder_command()
        .args([
            "instrument",
            "--build-dir",
            build_dir.to_str().unwrap(),
            "--source-dir",
            fixture_dir.to_str().unwrap(),
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("instrument standalone Erlang fixture");
    assert_eq!(output.status.code(), Some(0), "{}", output_text(&output));
    let after = fs::read(normal_ebin.join("standalone_main.beam")).expect("read original beam");
    assert_eq!(before, after, "normal build artifact changed");
    assert!(build_dir
        .join("instrumented/ebin/standalone_main.beam")
        .is_file());
    assert!(build_dir
        .join("recorder_metadata/manifests/standalone_main.manifest.json")
        .is_file());
    assert!(!fixture_dir.join("recorder_metadata").exists());
    assert!(
        !build_dir.join("erl.ct").exists(),
        "instrument must not run the target"
    );
}

#[test]
fn e2e_cli_module_filters_real_project() {
    let tmp = temp_dir("m11-module-filters");
    let fixture_dir = repo_root().join("test-programs/erlang/module_filters");
    let source_dir = fixture_dir.join("src");
    let original_ebin = tmp.join("original-ebin");
    let build_dir = tmp.join("filtered-build");
    let out_dir = tmp.join("trace");
    compile_erlang_sources(&source_dir, &original_ebin);

    let instrument = clean_recorder_command()
        .args([
            "instrument",
            "--build-dir",
            build_dir.to_str().unwrap(),
            "--source-dir",
            fixture_dir.to_str().unwrap(),
            "--include-module",
            "filter_entry",
            "--include-module",
            "filter_keep",
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("instrument filtered Erlang fixture");
    assert_eq!(
        instrument.status.code(),
        Some(0),
        "{}",
        output_text(&instrument)
    );
    assert!(build_dir
        .join("instrumented/ebin/filter_entry.beam")
        .is_file());
    assert!(build_dir
        .join("instrumented/ebin/filter_keep.beam")
        .is_file());
    assert!(!build_dir
        .join("instrumented/ebin/filter_skip.beam")
        .exists());

    let output = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            out_dir.to_str().unwrap(),
            "--build-dir",
            build_dir.to_str().unwrap(),
            "--root-mfa",
            "filter_entry:main/0",
            "--",
            "erl",
            "-noshell",
            "-pa",
            original_ebin.to_str().unwrap(),
        ])
        .current_dir(&fixture_dir)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("record filtered Erlang fixture");
    assert_eq!(output.status.code(), Some(0), "{}", output_text(&output));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "m11-filter:28\n");

    let reader = open_named_trace(&out_dir, "erl.ct");
    let call_names = reader_call_function_names(&reader);
    assert!(
        call_names
            .iter()
            .any(|name| name.contains("filter_entry:main/0")),
        "missing included entry call: {call_names:#?}"
    );
    assert!(
        call_names
            .iter()
            .any(|name| name.contains("filter_keep:run/1")),
        "missing included helper call: {call_names:#?}"
    );
    assert!(
        !call_names
            .iter()
            .any(|name| name.contains("filter_skip:run/1")),
        "excluded module should not produce traced calls: {call_names:#?}"
    );
    let location_index = manifest_location_index(&build_dir);
    let step_locations = runtime_sidecar_events(&out_dir)
        .into_iter()
        .filter(|event| event["event"] == "step")
        .map(|event| {
            let id = event["location_id"].as_u64().expect("step location_id");
            location_index
                .get(&id)
                .unwrap_or_else(|| panic!("step location_id {id} missing from build manifests"))
                .clone()
        })
        .collect::<Vec<_>>();
    assert!(
        !step_locations.is_empty(),
        "record should execute instrumented BEAMs before normal ebin paths"
    );
    assert!(
        step_locations
            .iter()
            .any(|(trace_copy_path, _, _)| trace_copy_path.contains("filter_entry.erl"))
            && step_locations
                .iter()
                .any(|(trace_copy_path, _, _)| trace_copy_path.contains("filter_keep.erl")),
        "included modules should emit instrumented steps: {step_locations:#?}"
    );
    assert!(
        !step_locations
            .iter()
            .any(|(trace_copy_path, _, _)| trace_copy_path.contains("filter_skip.erl")),
        "excluded module should not emit instrumented steps: {step_locations:#?}"
    );

    assert_recorder_error(
        clean_recorder_command()
            .args([
                "compile",
                "--build-dir",
                tmp.join("mismatch-build").to_str().unwrap(),
                "--source-dir",
                fixture_dir.to_str().unwrap(),
                "--include-module",
                "does_not_exist",
            ])
            .current_dir(&fixture_dir)
            .env("TMPDIR", tmp.to_str().unwrap())
            .output()
            .expect("run module filter mismatch scenario"),
        "module_filter_mismatch",
    );
}

#[test]
fn e2e_cli_capture_messages_switch_and_value_limits() {
    let tmp = temp_dir("m11-switches");

    let spawn_fixture = repo_root().join("test-programs/erlang/spawn_messages");
    let spawn_build_dir = tmp.join("spawn-build");
    let spawn_out_dir = tmp.join("spawn-trace");
    let compile_spawn = clean_recorder_command()
        .args([
            "compile",
            "--build-dir",
            spawn_build_dir.to_str().unwrap(),
            "--source-dir",
            spawn_fixture.to_str().unwrap(),
        ])
        .current_dir(&spawn_fixture)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("compile spawn fixture for message switch");
    assert_eq!(
        compile_spawn.status.code(),
        Some(0),
        "{}",
        output_text(&compile_spawn)
    );

    let no_messages = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            spawn_out_dir.to_str().unwrap(),
            "--build-dir",
            spawn_build_dir.to_str().unwrap(),
            "--root-mfa",
            "spawn_messages:main/0",
            "--capture-messages",
            "false",
            "--",
            "erl",
            "-noshell",
        ])
        .current_dir(&spawn_fixture)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("record spawn fixture with message capture disabled");
    assert_eq!(
        no_messages.status.code(),
        Some(0),
        "{}",
        output_text(&no_messages)
    );
    assert_eq!(String::from_utf8_lossy(&no_messages.stdout), "spawn-ok\n");
    let events = runtime_sidecar_events(&spawn_out_dir);
    assert!(
        sidecar_message_events(&events).is_empty(),
        "--capture-messages false should suppress send/receive sidecar events: {events:#?}"
    );
    assert_reader_thread_event(&spawn_out_dir, "erl.ct", "thread_start", 1);

    let value_fixture = repo_root().join("test-programs/erlang/value_matrix");
    let value_build_dir = tmp.join("value-build");
    let value_out_dir = tmp.join("value-trace");
    let compile_values = clean_recorder_command()
        .args([
            "compile",
            "--build-dir",
            value_build_dir.to_str().unwrap(),
            "--source-dir",
            value_fixture.to_str().unwrap(),
        ])
        .current_dir(&value_fixture)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("compile value matrix fixture for CLI value limits");
    assert_eq!(
        compile_values.status.code(),
        Some(0),
        "{}",
        output_text(&compile_values)
    );

    let limited = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            value_out_dir.to_str().unwrap(),
            "--build-dir",
            value_build_dir.to_str().unwrap(),
            "--root-mfa",
            "value_matrix:truncation/0",
            "--value-max-depth",
            "2",
            "--value-max-sequence-items",
            "3",
            "--value-max-binary-bytes",
            "4",
            "--value-max-map-pairs",
            "2",
            "--value-max-string-bytes",
            "5",
            "--",
            "erl",
            "-noshell",
        ])
        .current_dir(&value_fixture)
        .env("TMPDIR", tmp.to_str().unwrap())
        .output()
        .expect("record value matrix fixture with CLI value limits");
    assert_eq!(limited.status.code(), Some(0), "{}", output_text(&limited));
    assert_eq!(String::from_utf8_lossy(&limited.stdout), "truncation-ok\n");

    let values = raw_ctfs_low_level_values(&value_out_dir, "erl.ct");
    let long_list = find_named_value(&values, "LongList");
    assert!(matches!(
        long_list,
        ValueRecord::Sequence { elements, .. }
            if elements.len() == 4
                && matches!(elements.last(), Some(ValueRecord::Raw { r, .. }) if r == "[truncated]")
    ));
    assert!(matches!(
        find_named_value(&values, "LongString"),
        ValueRecord::String { text, .. } if text == "aaaaa..."
    ));
    assert!(matches!(
        find_named_value(&values, "LongRawBinary"),
        ValueRecord::Raw { r, .. } if r == "0x00FF1041..."
    ));
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

    let bad_source_dir = tmp.join("bad-source/src");
    fs::create_dir_all(&bad_source_dir).expect("create bad Erlang source dir");
    fs::write(
        bad_source_dir.join("bad_compile.erl"),
        b"-module(bad_compile).\n-export([main/0]).\nmain() ->\n",
    )
    .expect("write malformed Erlang source");
    assert_recorder_error(
        clean_recorder_command()
            .args([
                "compile",
                "--build-dir",
                tmp.join("bad-compile-build").to_str().unwrap(),
                "--source-dir",
                bad_source_dir.parent().unwrap().to_str().unwrap(),
            ])
            .current_dir(bad_source_dir.parent().unwrap())
            .env("TMPDIR", tmp.to_str().unwrap())
            .output()
            .expect("run compile failure scenario"),
        "compile_failure",
    );

    let bad_map_fixture = repo_root().join("test-programs/erlang/generated_source_map");
    let bad_map = tmp.join("bad-source-map.json");
    fs::write(&bad_map, b"{\"schema\":\"wrong\"}").expect("write invalid source map");
    assert_recorder_error(
        clean_recorder_command()
            .args([
                "compile",
                "--build-dir",
                tmp.join("bad-map-build").to_str().unwrap(),
                "--source-dir",
                bad_map_fixture.to_str().unwrap(),
                "--source-map",
                bad_map.to_str().unwrap(),
            ])
            .current_dir(&bad_map_fixture)
            .env("TMPDIR", tmp.to_str().unwrap())
            .output()
            .expect("run source-map failure scenario"),
        "source_map_failure",
    );

    let trace_write_out_dir = tmp.join("trace-write");
    let trace_write_failure = clean_recorder_command()
        .args([
            "record",
            "--out-dir",
            trace_write_out_dir.to_str().unwrap(),
            "--",
            "sh",
            "-c",
            &format!("rm -rf {}", trace_write_out_dir.display()),
        ])
        .output()
        .expect("run trace write failure scenario");
    assert_recorder_error(trace_write_failure, "trace_write_failure");
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
