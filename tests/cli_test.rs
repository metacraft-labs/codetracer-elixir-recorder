use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

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
