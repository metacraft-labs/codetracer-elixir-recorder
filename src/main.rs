use std::collections::{BTreeMap, HashMap};
use std::env;
use std::error::Error;
use std::fs;
use std::io;
use std::panic;
use std::path::{Path, PathBuf};
use std::process::{self, Command, ExitStatus};

use codetracer_ctfs::{ChunkedWriter, CompressionMethod, CtfsReader, CtfsWriter};
use codetracer_trace_format_cbor_zstd::HEADERV1;
use codetracer_trace_reader::{create_trace_reader, TraceEventsFileFormat as ReaderFormat};
use codetracer_trace_types::{
    EventLogKind, FieldTypeRecord, FullValueRecord, FunctionId, Line, TraceLowLevelEvent, TypeId,
    TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
};
use codetracer_trace_writer::trace_writer::TraceWriter as RustTraceWriter;
use codetracer_trace_writer_nim::{
    NimTraceReaderHandle, NimTraceWriter, TraceEventsFileFormat as NimFormat,
};
use serde::{Deserialize, Serialize};

const BINARY_NAME: &str = "codetracer-elixir-recorder";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const FIXTURE_PROGRAM: &str = "codetracer_elixir_m2_bridge";
const FIXTURE_SOURCE: &str = "test-programs/elixir/canonical_flow/lib/canonical_flow.ex";
const RUNTIME_APP_NAME: &str = "codetracer_erlang_runtime";
const RUNTIME_THREAD_ID: u64 = 1;

fn main() {
    match run() {
        Ok(code) => process::exit(code),
        Err(diagnostic) => {
            eprintln!("{}", diagnostic.to_json_line());
            process::exit(1);
        }
    }
}

fn run() -> Result<i32, RecorderDiagnostic> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();

    if args.is_empty() {
        print_help();
        return Ok(0);
    }

    match args.remove(0).as_str() {
        "-h" | "--help" => print_help(),
        "-V" | "--version" | "version" => print_version(),
        "record" => return record_command("record", args),
        "instrument" => return record_command("instrument", args),
        "compile" => return record_command("compile", args),
        "writer-fixture" => write_fixture(args)
            .map(|_| ())
            .map_err(|error| RecorderDiagnostic::writer_initialization_failed(error.to_string()))?,
        command => {
            return Err(RecorderDiagnostic::invalid_arguments(format!(
                "unknown command: {command}"
            )))
        }
    }

    Ok(0)
}

fn print_help() {
    println!(
        "{BINARY_NAME} - CodeTracer Elixir Recorder

Usage:
  {BINARY_NAME} record [OPTIONS] [--] COMMAND [ARGS...]
  {BINARY_NAME} instrument [OPTIONS] [--] COMMAND [ARGS...]
  {BINARY_NAME} compile [OPTIONS] [--] COMMAND [ARGS...]
  {BINARY_NAME} version

Options:
  -o, --out-dir PATH    Output directory for trace artifacts [default: ./ct-traces/]
  -f, --format FMT      Trace format: ctfs, binary, json [default: ctfs]
  -h, --help            Show this help text
  -V, --version         Show recorder version

Environment:
  CODETRACER_ELIXIR_RECORDER_OUT_DIR  Output directory overridden by --out-dir
  CODETRACER_FORMAT                   Trace format overridden by --format
  CODETRACER_ELIXIR_RECORDER_DISABLED Set to 1 or true to run target without recording"
    );
}

fn print_version() {
    println!("{BINARY_NAME} {VERSION}");
}

fn record_command(subcommand: &'static str, args: Vec<String>) -> Result<i32, RecorderDiagnostic> {
    match parse_record_options(args)? {
        ParsedRecordCommand::Help => {
            print_help();
            Ok(0)
        }
        ParsedRecordCommand::Version => {
            print_version();
            Ok(0)
        }
        ParsedRecordCommand::Record(options) => {
            if recording_disabled() {
                return run_target(&options.target).map(exit_code);
            }

            ensure_output_directory(&options.out_dir)?;
            let mut session = RecordingSession::begin(subcommand, &options)?;
            let status = run_prepared_target(&session.prepared_target)?;
            let code = exit_code(status);
            session.finish(code)?;
            Ok(code)
        }
    }
}

fn recording_disabled() -> bool {
    env::var("CODETRACER_ELIXIR_RECORDER_DISABLED")
        .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn run_target(target: &[String]) -> Result<ExitStatus, RecorderDiagnostic> {
    let prepared = PreparedTarget::plain(target.to_vec());
    run_prepared_target(&prepared)
}

fn run_prepared_target(target: &PreparedTarget) -> Result<ExitStatus, RecorderDiagnostic> {
    let mut command = Command::new(&target.command);
    command
        .args(&target.args)
        .envs(target.env.iter().map(|(key, value)| (key, value)));
    command
        .status()
        .map_err(|error| RecorderDiagnostic::target_spawn_failed(&target.command, error))
}

fn exit_code(status: ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

#[derive(Debug)]
enum ParsedRecordCommand {
    Help,
    Version,
    Record(RecordOptions),
}

#[derive(Clone, Debug)]
struct RecordOptions {
    out_dir: PathBuf,
    format: OutputFormat,
    target: Vec<String>,
}

#[derive(Clone, Debug)]
struct PreparedTarget {
    command: String,
    args: Vec<String>,
    env: Vec<(String, String)>,
    injection_decision: String,
}

impl PreparedTarget {
    fn plain(target: Vec<String>) -> Self {
        let mut iter = target.into_iter();
        let command = iter.next().unwrap_or_default();
        Self {
            command,
            args: iter.collect(),
            env: Vec::new(),
            injection_decision: "runtime not injected for non-BEAM target".to_string(),
        }
    }
}

fn parse_record_options(args: Vec<String>) -> Result<ParsedRecordCommand, RecorderDiagnostic> {
    let mut out_dir = env::var_os("CODETRACER_ELIXIR_RECORDER_OUT_DIR").map(PathBuf::from);
    let mut format = match env::var("CODETRACER_FORMAT") {
        Ok(value) => Some(OutputFormat::parse(&value)?),
        Err(_) => None,
    };
    let mut target = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = &args[index];
        match arg.as_str() {
            "--" => {
                target = args[index + 1..].to_vec();
                break;
            }
            "-h" | "--help" => return Ok(ParsedRecordCommand::Help),
            "-V" | "--version" => return Ok(ParsedRecordCommand::Version),
            "-o" | "--out-dir" => {
                index += 1;
                let Some(value) = args.get(index) else {
                    return Err(RecorderDiagnostic::invalid_arguments(format!(
                        "{arg} requires a path"
                    )));
                };
                out_dir = Some(PathBuf::from(value));
            }
            "-f" | "--format" => {
                index += 1;
                let Some(value) = args.get(index) else {
                    return Err(RecorderDiagnostic::invalid_arguments(format!(
                        "{arg} requires a format"
                    )));
                };
                format = Some(OutputFormat::parse(value)?);
            }
            _ if arg.starts_with("--out-dir=") => {
                out_dir = Some(PathBuf::from(arg.trim_start_matches("--out-dir=")));
            }
            _ if arg.starts_with("--format=") => {
                format = Some(OutputFormat::parse(arg.trim_start_matches("--format="))?);
            }
            _ if arg.starts_with('-') => {
                return Err(RecorderDiagnostic::invalid_arguments(format!(
                    "unknown recorder option before target separator: {arg}"
                )));
            }
            _ => {
                target = args[index..].to_vec();
                break;
            }
        }
        index += 1;
    }

    if target.is_empty() {
        return Err(RecorderDiagnostic::missing_target());
    }

    Ok(ParsedRecordCommand::Record(RecordOptions {
        out_dir: out_dir.unwrap_or_else(|| PathBuf::from("./ct-traces")),
        format: format.unwrap_or(OutputFormat::Ctfs),
        target,
    }))
}

fn ensure_output_directory(path: &Path) -> Result<(), RecorderDiagnostic> {
    if path.exists() && !path.is_dir() {
        return Err(RecorderDiagnostic::invalid_output_dir(
            path,
            "path exists but is not a directory",
        ));
    }

    fs::create_dir_all(path)
        .map_err(|error| RecorderDiagnostic::invalid_output_dir(path, error.to_string()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum OutputFormat {
    Ctfs,
    Binary,
    Json,
}

impl OutputFormat {
    fn parse(value: &str) -> Result<Self, RecorderDiagnostic> {
        match value {
            "ctfs" => Ok(Self::Ctfs),
            "binary" => Ok(Self::Binary),
            "json" => Ok(Self::Json),
            other => Err(RecorderDiagnostic::invalid_format(other)),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Ctfs => "ctfs",
            Self::Binary => "binary",
            Self::Json => "json",
        }
    }

    fn as_nim_format(self) -> NimFormat {
        match self {
            Self::Ctfs => NimFormat::Ctfs,
            Self::Binary => NimFormat::Binary,
            Self::Json => NimFormat::Json,
        }
    }
}

#[derive(Debug, Serialize)]
struct RecorderDiagnostic {
    #[serde(rename = "type")]
    diagnostic_type: &'static str,
    code: &'static str,
    message: String,
    detail: Option<String>,
}

impl RecorderDiagnostic {
    fn invalid_arguments(message: impl Into<String>) -> Self {
        Self::new("invalid_arguments", message.into(), None)
    }

    fn invalid_output_dir(path: &Path, detail: impl Into<String>) -> Self {
        Self::new(
            "invalid_output_dir",
            format!("invalid output directory: {}", path.display()),
            Some(detail.into()),
        )
    }

    fn invalid_format(format: &str) -> Self {
        Self::new(
            "invalid_format",
            format!("invalid trace format: {format}"),
            Some("expected one of: ctfs, binary, json".to_string()),
        )
    }

    fn missing_target() -> Self {
        Self::new(
            "missing_target",
            "record requires a target command".to_string(),
            Some(
                "pass target arguments after recorder options, optionally separated by --"
                    .to_string(),
            ),
        )
    }

    fn writer_initialization_failed(detail: impl Into<String>) -> Self {
        Self::new(
            "writer_initialization_failed",
            "failed to initialize trace writer".to_string(),
            Some(detail.into()),
        )
    }

    fn runtime_bootstrap_failed(detail: impl Into<String>) -> Self {
        Self::new(
            "runtime_bootstrap_failed",
            "failed to prepare BEAM runtime session".to_string(),
            Some(detail.into()),
        )
    }

    fn writer_finalization_failed(detail: impl Into<String>) -> Self {
        Self::new(
            "writer_finalization_failed",
            "failed to finalize trace writer".to_string(),
            Some(detail.into()),
        )
    }

    fn target_spawn_failed(command: &str, error: io::Error) -> Self {
        Self::new(
            "target_spawn_failed",
            format!("failed to execute target command: {command}"),
            Some(error.to_string()),
        )
    }

    fn new(code: &'static str, message: String, detail: Option<String>) -> Self {
        Self {
            diagnostic_type: "recorder_error",
            code,
            message,
            detail,
        }
    }

    fn to_json_line(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            r#"{"type":"recorder_error","code":"diagnostic_serialization_failed"}"#.to_string()
        })
    }
}

struct RecordingSession {
    writer: NimTraceWriter,
    out_dir: PathBuf,
    program_name: String,
    subcommand: &'static str,
    options: RecordOptions,
    runtime: RuntimeSession,
    prepared_target: PreparedTarget,
    pending_drop_variable_names: Vec<Vec<String>>,
    pending_value_events: Vec<PendingValueEvent>,
}

impl RecordingSession {
    fn begin(
        subcommand: &'static str,
        options: &RecordOptions,
    ) -> Result<Self, RecorderDiagnostic> {
        let program_name = target_program_name(&options.target[0]);
        let runtime = RuntimeSession::prepare(options)?;
        let prepared_target = runtime.prepare_target(&options.target)?;
        let writer = panic::catch_unwind({
            let program_name = program_name.clone();
            let format = options.format.as_nim_format();
            move || NimTraceWriter::new(&program_name, format)
        })
        .map_err(|payload| {
            RecorderDiagnostic::writer_initialization_failed(panic_payload(payload))
        })?;

        let mut session = Self {
            writer,
            out_dir: options.out_dir.clone(),
            program_name,
            subcommand,
            options: options.clone(),
            runtime,
            prepared_target,
            pending_drop_variable_names: Vec::new(),
            pending_value_events: Vec::new(),
        };
        session.initialize_writer()?;
        Ok(session)
    }

    fn initialize_writer(&mut self) -> Result<(), RecorderDiagnostic> {
        let current_dir = env::current_dir().map_err(|error| {
            RecorderDiagnostic::writer_initialization_failed(format!(
                "failed to read current directory: {error}"
            ))
        })?;
        let metadata_path = self.out_dir.join("trace_metadata.json");
        let events_path = self.out_dir.join("trace.json");
        let paths_path = self.out_dir.join("trace_paths.json");
        let source_path = self
            .runtime
            .source_paths
            .first()
            .cloned()
            .unwrap_or_else(|| recording_anchor_path(&self.options.target[0]));

        let write_probe_path = self.out_dir.join(".codetracer-writer-init-check");
        fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&write_probe_path)
            .and_then(|_| fs::remove_file(&write_probe_path))
            .map_err(|error| RecorderDiagnostic::writer_initialization_failed(error.to_string()))?;

        self.writer.set_workdir(&current_dir);
        self.writer
            .begin_writing_trace_metadata(&metadata_path)
            .map_err(|error| RecorderDiagnostic::writer_initialization_failed(error.to_string()))?;
        self.writer
            .finish_writing_trace_metadata()
            .map_err(|error| RecorderDiagnostic::writer_initialization_failed(error.to_string()))?;
        self.writer
            .begin_writing_trace_events(&events_path)
            .map_err(|error| RecorderDiagnostic::writer_initialization_failed(error.to_string()))?;
        self.writer
            .begin_writing_trace_paths(&paths_path)
            .map_err(|error| RecorderDiagnostic::writer_initialization_failed(error.to_string()))?;
        self.writer
            .finish_writing_trace_paths()
            .map_err(|error| RecorderDiagnostic::writer_initialization_failed(error.to_string()))?;
        self.writer.start(&source_path, Line(1));

        Ok(())
    }

    fn finish(&mut self, target_exit_code: i32) -> Result<(), RecorderDiagnostic> {
        let runtime_result = self.runtime.read_delivery()?;
        if runtime_result.delivered {
            self.write_runtime_trace_events(&runtime_result)?;
        }
        self.writer.register_special_event(
            EventLogKind::Write,
            "m4",
            &format!(
                "runtime_session delivered={} injection={}",
                runtime_result.delivered, self.prepared_target.injection_decision
            ),
        );
        self.writer
            .finish_writing_trace_events()
            .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))?;
        self.writer
            .write_meta_dat(BINARY_NAME)
            .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))?;
        self.writer
            .close()
            .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))?;
        self.write_ctfs_runtime_events()?;

        write_trace_meta_json(self, &runtime_result, target_exit_code)
            .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))
    }

    fn write_runtime_trace_events(
        &mut self,
        runtime_result: &RuntimeDelivery,
    ) -> Result<(), RecorderDiagnostic> {
        let mut interner = FunctionInterner::new(&self.runtime.trace_functions);
        let location_index = self
            .runtime
            .step_locations
            .iter()
            .map(|location| (location.location_id, location))
            .collect::<HashMap<_, _>>();
        for event in &runtime_result.trace_events {
            match event {
                RuntimeTraceEvent::ThreadStart { thread_id, .. } => {
                    self.writer.register_thread_start(*thread_id);
                }
                RuntimeTraceEvent::ThreadSwitch { thread_id, .. } => {
                    self.writer.register_thread_switch(*thread_id);
                }
                RuntimeTraceEvent::ThreadExit { thread_id, .. } => {
                    self.writer.register_thread_exit(*thread_id);
                }
                RuntimeTraceEvent::Call {
                    module,
                    function,
                    arity,
                    args,
                    source_language,
                    manifest_id,
                    function_key,
                    location_id,
                    clause_id,
                    source_location,
                } => {
                    let function_id = interner.ensure_id(
                        &mut self.writer,
                        module,
                        function,
                        *arity,
                        &self.runtime.source_root,
                        source_location.as_ref(),
                    );
                    let args = args
                        .iter()
                        .enumerate()
                        .map(|(index, value)| {
                            let arg_name = format!("_arg{index}");
                            self.pending_value_events.push(PendingValueEvent {
                                variable_name: arg_name.clone(),
                                value: value.clone(),
                            });
                            let trace_value = json_to_trace_value(&mut self.writer, value);
                            self.writer.arg(&arg_name, trace_value)
                        })
                        .collect::<Vec<_>>();
                    if manifest_id.is_some() || location_id.is_some() {
                        let payload = serde_json::json!({
                            "schema": "codetracer.beam.source-location.v1",
                            "module": module,
                            "function": function,
                            "arity": arity,
                            "source_language": source_language,
                            "manifest_id": manifest_id,
                            "function_key": function_key,
                            "location_id": location_id,
                            "clause_id": clause_id,
                            "source_location": source_location,
                        });
                        self.writer.register_special_event(
                            EventLogKind::TraceLogEvent,
                            "beam_source_location",
                            &payload.to_string(),
                        );
                    }
                    self.writer.register_call(function_id, args);
                }
                RuntimeTraceEvent::Step { location_id } => {
                    let Some(location) = location_index.get(location_id) else {
                        return Err(RecorderDiagnostic::writer_finalization_failed(format!(
                            "runtime emitted step for unknown location_id {location_id}"
                        )));
                    };
                    self.writer.register_step(
                        &location.resolved_source_path,
                        Line(location.resolved_line),
                    );
                }
                RuntimeTraceEvent::Return {
                    return_value: Some(value),
                    ..
                } => {
                    let trace_value = json_to_trace_value(&mut self.writer, value);
                    self.writer.register_return(trace_value);
                }
                RuntimeTraceEvent::Return {
                    return_value: None, ..
                } => {
                    let none_type = self.writer.ensure_type_id(TypeKind::None, "None");
                    self.writer
                        .register_return(ValueRecord::None { type_id: none_type });
                }
                RuntimeTraceEvent::VariableBind {
                    frame_id,
                    runtime_variable_id,
                    slot,
                    slot_template,
                    name,
                    value,
                } => {
                    self.pending_value_events.push(PendingValueEvent {
                        variable_name: name.clone(),
                        value: value.clone(),
                    });
                    let trace_value = json_to_trace_value(&mut self.writer, value);
                    self.writer
                        .register_variable_with_full_value(name, trace_value);
                    let payload = serde_json::json!({
                        "schema": "codetracer.beam.variable-binding.v1",
                        "event": "variable_bind",
                        "frame_id": frame_id,
                        "runtime_variable_id": runtime_variable_id,
                        "slot": slot,
                        "slot_template": slot_template,
                        "name": name,
                    });
                    self.writer.register_special_event(
                        EventLogKind::TraceLogEvent,
                        "beam_variable_binding",
                        &payload.to_string(),
                    );
                }
                RuntimeTraceEvent::DropVariables {
                    frame_id,
                    variables,
                } => {
                    let names = variables
                        .iter()
                        .map(|variable| variable.name.clone())
                        .collect::<Vec<_>>();
                    self.writer.drop_variables(&names);
                    self.pending_drop_variable_names.push(names);
                    let payload = serde_json::json!({
                        "schema": "codetracer.beam.variable-binding.v1",
                        "event": "drop_variables",
                        "frame_id": frame_id,
                        "variables": variables,
                    });
                    self.writer.register_special_event(
                        EventLogKind::TraceLogEvent,
                        "beam_variable_binding",
                        &payload.to_string(),
                    );
                }
                RuntimeTraceEvent::Exception {
                    module,
                    function,
                    arity,
                    class,
                    reason,
                    reason_repr,
                } => {
                    let payload = serde_json::json!({
                        "schema": "codetracer.elixir.exception_from.v1",
                        "module": module,
                        "function": function,
                        "arity": arity,
                        "class": class,
                        "reason": reason,
                        "reason_repr": reason_repr,
                    });
                    self.writer.register_special_event(
                        EventLogKind::Error,
                        "exception_from",
                        &payload.to_string(),
                    );
                }
                RuntimeTraceEvent::Message { payload } => {
                    let content = serde_json::to_string(payload).map_err(|error| {
                        RecorderDiagnostic::writer_finalization_failed(error.to_string())
                    })?;
                    self.writer.register_special_event(
                        EventLogKind::TraceLogEvent,
                        "beam_message",
                        &content,
                    );
                }
            }
        }

        Ok(())
    }

    fn write_ctfs_runtime_events(&self) -> Result<(), RecorderDiagnostic> {
        if !matches!(
            self.options.format,
            OutputFormat::Ctfs | OutputFormat::Binary
        ) || (self.pending_drop_variable_names.is_empty()
            && self.pending_value_events.is_empty())
        {
            return Ok(());
        }

        let trace_path = self.out_dir.join(format!("{}.ct", self.program_name));
        append_runtime_events_to_ctfs(
            &trace_path,
            &self.pending_value_events,
            &self.pending_drop_variable_names,
        )
        .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))
    }
}

fn append_runtime_events_to_ctfs(
    trace_path: &Path,
    pending_values: &[PendingValueEvent],
    drop_variable_groups: &[Vec<String>],
) -> Result<(), Box<dyn Error>> {
    let mut reader = CtfsReader::open(trace_path)?;
    let files = reader.list_files();
    let has_events_log = files.iter().any(|name| name == "events.log");
    let has_events_fmt = files.iter().any(|name| name == "events.fmt");
    if has_events_log {
        let format = reader.read_file("events.fmt")?;
        if format.as_slice() != b"split-binary" {
            return Err(format!(
                "cannot append DropVariables to {}: unsupported events.fmt {:?}",
                trace_path.display(),
                String::from_utf8_lossy(&format)
            )
            .into());
        }
    }

    let existing_events = if has_events_log {
        codetracer_trace_reader::ctfs_reader::read_trace_from_ctfs(trace_path)?
    } else {
        Vec::new()
    };
    let mut variable_names = Vec::new();
    for event in &existing_events {
        match event {
            TraceLowLevelEvent::VariableName(name) | TraceLowLevelEvent::Variable(name) => {
                variable_names.push(name.clone());
            }
            _ => {}
        }
    }
    let mut variable_ids = variable_names
        .iter()
        .enumerate()
        .map(|(id, name)| (name.clone(), VariableId(id)))
        .collect::<BTreeMap<_, _>>();
    let mut type_records = Vec::new();
    for event in &existing_events {
        if let TraceLowLevelEvent::Type(record) = event {
            type_records.push(record.clone());
        }
    }
    let mut type_ids = type_records
        .iter()
        .enumerate()
        .map(|(id, record)| (type_record_key(record), TypeId(id)))
        .collect::<BTreeMap<_, _>>();

    let mut events = Vec::new();
    for pending in pending_values {
        let variable_id = ensure_low_level_variable(
            &pending.variable_name,
            &mut variable_names,
            &mut variable_ids,
            &mut events,
        );
        let value = json_to_low_level_trace_value(
            &pending.value,
            &mut type_records,
            &mut type_ids,
            &mut events,
        )?;
        events.push(TraceLowLevelEvent::Value(FullValueRecord {
            variable_id,
            value,
        }));
    }
    for group in drop_variable_groups {
        let mut ids = Vec::new();
        for name in group {
            let id = ensure_low_level_variable(
                name,
                &mut variable_names,
                &mut variable_ids,
                &mut events,
            );
            ids.push(id);
        }
        if !ids.is_empty() {
            events.push(TraceLowLevelEvent::DropVariables(ids));
        }
    }
    if events.is_empty() {
        return Ok(());
    }

    let mut encoded = Vec::new();
    let mut event_sizes = Vec::new();
    let mut first_geids = Vec::new();
    let first_geid = existing_events.len() as u64;
    for (index, event) in events.iter().enumerate() {
        let start = encoded.len();
        codetracer_trace_writer::split_binary::encode_event(event, &mut encoded)?;
        event_sizes.push(encoded.len() - start);
        first_geids.push(first_geid + index as u64);
    }
    let chunked = ChunkedWriter::new(CompressionMethod::Zstd, events.len()).write_chunked(
        &encoded,
        &event_sizes,
        &first_geids,
    )?;

    let mut writer = CtfsWriter::open_append(trace_path)?;
    let events_handle = if let Some(handle) = writer.find_file("events.log") {
        handle
    } else {
        let handle = writer.add_file("events.log")?;
        writer.write(handle, HEADERV1)?;
        writer.sync_entry(handle)?;
        handle
    };
    writer.write(events_handle, &chunked)?;
    writer.sync_entry(events_handle)?;

    if !has_events_fmt {
        let format_handle = writer.add_file("events.fmt")?;
        writer.write(format_handle, b"split-binary")?;
        writer.sync_entry(format_handle)?;
    }

    writer.close()?;
    Ok(())
}

fn ensure_low_level_variable(
    name: &str,
    variable_names: &mut Vec<String>,
    variable_ids: &mut BTreeMap<String, VariableId>,
    events: &mut Vec<TraceLowLevelEvent>,
) -> VariableId {
    if let Some(id) = variable_ids.get(name) {
        *id
    } else {
        let id = VariableId(variable_names.len());
        variable_names.push(name.to_string());
        variable_ids.insert(name.to_string(), id);
        events.push(TraceLowLevelEvent::VariableName(name.to_string()));
        id
    }
}

fn type_record_key(record: &TypeRecord) -> String {
    format!(
        "{:?}\x1f{}\x1f{:?}",
        record.kind, record.lang_type, record.specific_info
    )
}

fn ensure_low_level_type(
    kind: TypeKind,
    lang_type: &str,
    specific_info: TypeSpecificInfo,
    type_records: &mut Vec<TypeRecord>,
    type_ids: &mut BTreeMap<String, TypeId>,
    events: &mut Vec<TraceLowLevelEvent>,
) -> TypeId {
    let record = TypeRecord {
        kind,
        lang_type: lang_type.to_string(),
        specific_info,
    };
    let key = type_record_key(&record);
    if let Some(id) = type_ids.get(&key) {
        *id
    } else {
        let id = TypeId(type_records.len());
        type_records.push(record.clone());
        type_ids.insert(key, id);
        events.push(TraceLowLevelEvent::Type(record));
        id
    }
}

#[derive(Clone, Debug)]
struct RuntimeSession {
    mode: RuntimeMode,
    session_file: PathBuf,
    runtime_ebin: Option<PathBuf>,
    instrumented_ebin: Option<PathBuf>,
    source_root: PathBuf,
    source_paths: Vec<PathBuf>,
    copied_sources: Vec<CopiedSource>,
    manifests: Vec<ManifestArtifact>,
    source_maps: Vec<SourceMapArtifact>,
    transformed_form_dumps: Vec<TransformedFormsDump>,
    trace_functions: Vec<TraceFunctionSpec>,
    step_locations: Vec<TraceLocationSpec>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuntimeMode {
    Beam,
    NonBeam,
}

#[derive(Clone, Debug, Serialize)]
struct CopiedSource {
    source_path: String,
    bundle_path: String,
    build_path: String,
    project_relative_path: String,
    trace_copy_path: String,
}

#[derive(Clone, Debug, Serialize)]
struct ManifestArtifact {
    module: String,
    manifest_id: String,
    encoding: String,
    schema: String,
    build_path: String,
    trace_copy_path: String,
    #[serde(skip_serializing)]
    runtime_path: String,
}

#[derive(Clone, Debug, Serialize)]
struct SourceMapArtifact {
    source_language: String,
    generated_build_path: String,
    original_build_path: String,
    trace_copy_path: String,
}

#[derive(Clone, Debug, Serialize)]
struct TransformedFormsDump {
    module: String,
    format: String,
    build_path: String,
    trace_copy_path: String,
    #[serde(skip_serializing)]
    runtime_path: String,
}

#[derive(Debug)]
struct RuntimeDelivery {
    delivered: bool,
    root_thread_id: u64,
    root_pid: Option<String>,
    trace_events: Vec<RuntimeTraceEvent>,
}

#[derive(Debug, Deserialize)]
struct RuntimeSidecarEvent {
    event: String,
    thread_id: Option<u64>,
    pid: Option<String>,
    root_pid: Option<String>,
    module: Option<String>,
    function: Option<String>,
    arity: Option<u32>,
    args: Option<Vec<serde_json::Value>>,
    return_value: Option<serde_json::Value>,
    class: Option<String>,
    reason: Option<serde_json::Value>,
    reason_repr: Option<String>,
    frame_id: Option<u64>,
    runtime_variable_id: Option<u64>,
    slot: Option<u32>,
    slot_template: Option<String>,
    name: Option<String>,
    value: Option<serde_json::Value>,
    variables: Option<Vec<RuntimeDroppedVariable>>,
    schema: Option<String>,
    direction: Option<String>,
    trace_tag: Option<String>,
    tag: Option<String>,
    sender_pid: Option<String>,
    sender_thread_id: Option<u64>,
    recipient_pid: Option<String>,
    recipient_thread_id: Option<u64>,
    message_format: Option<String>,
    message_repr: Option<String>,
    message_truncated: Option<bool>,
    manifest_id: Option<String>,
    function_key: Option<String>,
    location_id: Option<u32>,
    clause_id: Option<u32>,
    source_location: Option<ResolvedSourceLocation>,
    source_language: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct TraceLocationSpec {
    module: String,
    source_path: PathBuf,
    location_id: u32,
    resolved_source_path: PathBuf,
    resolved_line: i64,
    resolved_column: Option<u32>,
    resolution_strategy: String,
    trace_copy_path: String,
    generated: bool,
}

#[derive(Debug)]
struct InstrumentationArtifacts {
    ebin_dir: Option<PathBuf>,
    locations: Vec<TraceLocationSpec>,
    variable_slot_templates: Vec<ManifestVariableSlotTemplate>,
    dumps: Vec<TransformedFormsDump>,
}

#[derive(Debug, Deserialize)]
struct StepLocationsFile {
    schema: String,
    module: String,
    source_path: String,
    #[serde(default)]
    variable_slot_templates: Vec<RawVariableSlotTemplate>,
    locations: Vec<RawStepLocation>,
}

#[derive(Debug, Deserialize)]
struct RawStepLocation {
    id: u32,
    source_path: String,
    line: i64,
    column: Option<u32>,
    generated: bool,
}

#[derive(Debug, Deserialize)]
struct RawVariableSlotTemplate {
    function_key: String,
    slot: u32,
    name: String,
    source: String,
}

#[derive(Clone, Debug, Serialize)]
struct TraceFunctionSpec {
    module: String,
    function: String,
    arity: u32,
    kind: String,
    source_path: PathBuf,
    line: i64,
    manifest_id: String,
    function_key: String,
    location_id: u32,
    clause_id: u32,
    resolved_source_path: PathBuf,
    resolved_line: i64,
    resolved_column: Option<u32>,
    resolution_strategy: String,
    trace_copy_path: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ResolvedSourceLocation {
    build_path: String,
    trace_copy_path: String,
    line: i64,
    column: Option<u32>,
    resolution: String,
}

#[derive(Clone, Debug)]
enum RuntimeTraceEvent {
    ThreadStart {
        thread_id: u64,
    },
    ThreadSwitch {
        thread_id: u64,
    },
    ThreadExit {
        thread_id: u64,
    },
    Call {
        module: String,
        function: String,
        arity: u32,
        args: Vec<serde_json::Value>,
        source_language: Option<String>,
        manifest_id: Option<String>,
        function_key: Option<String>,
        location_id: Option<u32>,
        clause_id: Option<u32>,
        source_location: Option<ResolvedSourceLocation>,
    },
    Step {
        location_id: u32,
    },
    Return {
        return_value: Option<serde_json::Value>,
    },
    VariableBind {
        frame_id: u64,
        runtime_variable_id: u64,
        slot: u32,
        slot_template: String,
        name: String,
        value: serde_json::Value,
    },
    DropVariables {
        frame_id: u64,
        variables: Vec<RuntimeDroppedVariable>,
    },
    Exception {
        module: String,
        function: String,
        arity: u32,
        class: String,
        reason: serde_json::Value,
        reason_repr: String,
    },
    Message {
        payload: BeamMessagePayload,
    },
}

#[derive(Clone, Debug, Serialize)]
struct BeamMessagePayload {
    schema: String,
    direction: String,
    trace_tag: String,
    tag: String,
    sender_pid: Option<String>,
    sender_thread_id: Option<u64>,
    recipient_pid: Option<String>,
    recipient_thread_id: Option<u64>,
    message_format: String,
    message_repr: String,
    message_truncated: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RuntimeDroppedVariable {
    runtime_variable_id: u64,
    slot: u32,
    slot_template: String,
    name: String,
}

#[derive(Clone, Debug)]
struct PendingValueEvent {
    variable_name: String,
    value: serde_json::Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct SparseSourceMap {
    schema: String,
    source_language: String,
    generated_path: String,
    original_path: String,
    mappings: Vec<SparseSourceMapEntry>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct SparseSourceMapEntry {
    generated_line: i64,
    generated_column: Option<u32>,
    original_line: i64,
    original_column: Option<u32>,
    reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ModuleManifest {
    schema: String,
    encoding: String,
    manifest_id: String,
    module: ManifestModuleIdentity,
    functions: Vec<ManifestFunction>,
    locations: Vec<ManifestLocation>,
    clauses: Vec<ManifestClause>,
    variable_slot_templates: Vec<ManifestVariableSlotTemplate>,
    traceable_mfas: Vec<ManifestMfa>,
    source_maps: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ManifestModuleIdentity {
    name: String,
    source_language: String,
    build_path: String,
    project_relative_path: String,
    trace_copy_path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ManifestFunction {
    key: String,
    name: String,
    arity: u32,
    visibility: String,
    location_id: u32,
    clause_ids: Vec<u32>,
    traceable: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ManifestLocation {
    id: u32,
    build_path: String,
    project_relative_path: String,
    trace_copy_path: String,
    line: i64,
    column: Option<u32>,
    resolution: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ManifestClause {
    id: u32,
    function_key: String,
    location_id: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ManifestVariableSlotTemplate {
    function_key: String,
    slot: u32,
    name: String,
    source: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ManifestMfa {
    module: String,
    function: String,
    arity: u32,
}

impl RuntimeSession {
    fn prepare(options: &RecordOptions) -> Result<Self, RecorderDiagnostic> {
        let source_root = env::current_dir().map_err(|error| {
            RecorderDiagnostic::runtime_bootstrap_failed(format!(
                "failed to read current directory: {error}"
            ))
        })?;
        let mode = if is_beam_target(&options.target[0]) {
            RuntimeMode::Beam
        } else {
            RuntimeMode::NonBeam
        };
        let source_paths = if mode == RuntimeMode::Beam {
            discover_source_paths(&source_root)
                .map_err(|error| RecorderDiagnostic::runtime_bootstrap_failed(error.to_string()))?
        } else {
            Vec::new()
        };
        let discovered_source_maps = if mode == RuntimeMode::Beam {
            discover_source_maps(&source_root)
                .map_err(|error| RecorderDiagnostic::runtime_bootstrap_failed(error.to_string()))?
        } else {
            Vec::new()
        };
        let trace_functions = if mode == RuntimeMode::Beam {
            discover_trace_functions(&source_root, &source_paths, &discovered_source_maps)
                .map_err(|error| RecorderDiagnostic::runtime_bootstrap_failed(error.to_string()))?
        } else {
            Vec::new()
        };
        let copied_sources = if mode == RuntimeMode::Beam {
            copy_sources(&options.out_dir, &source_root, &source_paths)
                .map_err(|error| RecorderDiagnostic::runtime_bootstrap_failed(error.to_string()))?
        } else {
            Vec::new()
        };
        let session_file = options.out_dir.join("runtime_session.jsonl");
        let runtime_ebin = if mode == RuntimeMode::Beam {
            Some(
                compile_runtime_app(&options.out_dir, &options.target[0]).map_err(|error| {
                    RecorderDiagnostic::runtime_bootstrap_failed(error.to_string())
                })?,
            )
        } else {
            None
        };
        let instrumentation = if mode == RuntimeMode::Beam {
            let runtime_ebin = runtime_ebin.as_ref().ok_or_else(|| {
                RecorderDiagnostic::runtime_bootstrap_failed(
                    "missing compiled runtime ebin before instrumentation",
                )
            })?;
            instrument_erlang_sources(
                &options.out_dir,
                &source_root,
                &source_paths,
                runtime_ebin,
                &discovered_source_maps,
            )
            .map_err(|error| RecorderDiagnostic::runtime_bootstrap_failed(error.to_string()))?
        } else {
            InstrumentationArtifacts {
                ebin_dir: None,
                locations: Vec::new(),
                variable_slot_templates: Vec::new(),
                dumps: Vec::new(),
            }
        };
        let (manifests, source_maps) = if mode == RuntimeMode::Beam {
            write_recorder_metadata(
                &options.out_dir,
                &source_root,
                &trace_functions,
                &instrumentation.locations,
                &instrumentation.variable_slot_templates,
                &discovered_source_maps,
                &instrumentation.dumps,
            )
            .map_err(|error| RecorderDiagnostic::runtime_bootstrap_failed(error.to_string()))?
        } else {
            (Vec::new(), Vec::new())
        };

        Ok(Self {
            mode,
            session_file,
            runtime_ebin,
            instrumented_ebin: instrumentation.ebin_dir,
            source_root,
            source_paths,
            copied_sources,
            manifests,
            source_maps,
            transformed_form_dumps: instrumentation.dumps,
            trace_functions,
            step_locations: instrumentation.locations,
        })
    }

    fn prepare_target(&self, target: &[String]) -> Result<PreparedTarget, RecorderDiagnostic> {
        if self.mode == RuntimeMode::NonBeam {
            return Ok(PreparedTarget::plain(target.to_vec()));
        }

        let Some(runtime_ebin) = &self.runtime_ebin else {
            return Err(RecorderDiagnostic::runtime_bootstrap_failed(
                "missing compiled runtime ebin directory",
            ));
        };
        let command_name = target_program_name(&target[0]);
        match command_name.as_str() {
            "mix" => self.prepare_mix_target(target, runtime_ebin),
            "erl" => self.prepare_erl_target(target, runtime_ebin),
            "rebar3" => Err(RecorderDiagnostic::runtime_bootstrap_failed(
                "Rebar3 runtime injection decision: use the same -pa runtime ebin plus wrapper bootstrap policy as plain erl; dedicated Rebar3 task integration is deferred past M4",
            )),
            other => Err(RecorderDiagnostic::runtime_bootstrap_failed(format!(
                "unsupported BEAM target for M4 runtime injection: {other}"
            ))),
        }
    }

    fn prepare_mix_target(
        &self,
        target: &[String],
        _runtime_ebin: &Path,
    ) -> Result<PreparedTarget, RecorderDiagnostic> {
        let mut prepared = PreparedTarget::plain(target.to_vec());
        let expression_index = prepared
            .args
            .iter()
            .position(|arg| arg == "-e" || arg == "--eval")
            .ok_or_else(|| {
                RecorderDiagnostic::runtime_bootstrap_failed(
                    "M4 Mix injection requires a mix run -e/--eval target expression",
                )
            })?;
        let Some(expression) = prepared.args.get(expression_index + 1).cloned() else {
            return Err(RecorderDiagnostic::runtime_bootstrap_failed(
                "Mix -e/--eval is missing an expression to wrap",
            ));
        };
        prepared.args[expression_index + 1] = wrap_elixir_expression(&expression, self);
        prepared.injection_decision =
            "Mix M4 injection: wrap mix run -e/--eval with code.add_patha for the compiled runtime ebin plus start_session/stop_session".to_string();
        Ok(prepared)
    }

    fn prepare_erl_target(
        &self,
        target: &[String],
        runtime_ebin: &Path,
    ) -> Result<PreparedTarget, RecorderDiagnostic> {
        let mut args = target[1..].to_vec();
        let Some((module, function)) = extract_erl_start_function(&mut args) else {
            return Err(RecorderDiagnostic::runtime_bootstrap_failed(
                "M4 plain erl injection requires a -s Module Function target entry point",
            ));
        };
        remove_erl_init_stop(&mut args);
        args.push("-pa".to_string());
        args.push(runtime_ebin.display().to_string());
        if let Some(instrumented_ebin) = &self.instrumented_ebin {
            args.push("-pa".to_string());
            args.push(instrumented_ebin.display().to_string());
        }
        args.push("-eval".to_string());
        args.push(wrap_erlang_entrypoint(&module, &function, self));

        Ok(PreparedTarget {
            command: target[0].clone(),
            args,
            env: Vec::new(),
            injection_decision:
                "plain erl M4 injection plus M8 instrumentation: add -pa compiled runtime ebin and instrumented ebin, replace -s entrypoint/-s init stop with an -eval wrapper that starts and stops the runtime session"
                    .to_string(),
        })
    }

    fn read_delivery(&self) -> Result<RuntimeDelivery, RecorderDiagnostic> {
        if self.mode == RuntimeMode::NonBeam {
            return Ok(RuntimeDelivery {
                delivered: false,
                root_thread_id: RUNTIME_THREAD_ID,
                root_pid: None,
                trace_events: Vec::new(),
            });
        }

        let text = fs::read_to_string(&self.session_file).map_err(|error| {
            RecorderDiagnostic::writer_finalization_failed(format!(
                "runtime session sidecar was not written at {}: {error}",
                self.session_file.display()
            ))
        })?;
        let mut saw_start = false;
        let mut saw_switch = false;
        let mut saw_exit = false;
        let mut delivered = false;
        let mut root_pid = None;
        let root_thread_id = RUNTIME_THREAD_ID;
        let mut trace_events = Vec::new();

        for (line_number, line) in text.lines().enumerate() {
            let event: RuntimeSidecarEvent = serde_json::from_str(line).map_err(|error| {
                RecorderDiagnostic::writer_finalization_failed(format!(
                    "invalid runtime session JSON on line {}: {error}",
                    line_number + 1
                ))
            })?;
            match event.event.as_str() {
                "thread_start" => {
                    let thread_id = event.thread_id.unwrap_or(root_thread_id);
                    if thread_id == root_thread_id {
                        saw_start = true;
                        root_pid = event.root_pid.clone().or(event.pid.clone());
                    }
                    trace_events.push(RuntimeTraceEvent::ThreadStart { thread_id });
                }
                "thread_switch" => {
                    let thread_id = event.thread_id.unwrap_or(root_thread_id);
                    if thread_id == root_thread_id {
                        saw_switch = true;
                    }
                    trace_events.push(RuntimeTraceEvent::ThreadSwitch { thread_id });
                }
                "thread_exit" => {
                    let thread_id = event.thread_id.unwrap_or(root_thread_id);
                    if thread_id == root_thread_id {
                        saw_exit = true;
                    }
                    trace_events.push(RuntimeTraceEvent::ThreadExit { thread_id });
                }
                "trace_delivered" => delivered = true,
                "step" => {
                    trace_events.push(RuntimeTraceEvent::Step {
                        location_id: event.location_id.ok_or_else(|| {
                            RecorderDiagnostic::writer_finalization_failed(format!(
                                "runtime sidecar line {} missing required field location_id",
                                line_number + 1
                            ))
                        })?,
                    });
                }
                "call" => {
                    trace_events.push(RuntimeTraceEvent::Call {
                        module: require_sidecar_string(&event, "module", line_number + 1)?,
                        function: require_sidecar_string(&event, "function", line_number + 1)?,
                        arity: require_sidecar_u32(&event, "arity", line_number + 1)?,
                        args: event.args.unwrap_or_default(),
                        source_language: event.source_language,
                        manifest_id: event.manifest_id,
                        function_key: event.function_key,
                        location_id: event.location_id,
                        clause_id: event.clause_id,
                        source_location: event.source_location,
                    });
                }
                "return_from" => {
                    trace_events.push(RuntimeTraceEvent::Return {
                        return_value: event.return_value,
                    });
                }
                "variable_bind" => {
                    trace_events.push(RuntimeTraceEvent::VariableBind {
                        frame_id: event.frame_id.ok_or_else(|| {
                            RecorderDiagnostic::writer_finalization_failed(format!(
                                "runtime sidecar line {} missing required field frame_id",
                                line_number + 1
                            ))
                        })?,
                        runtime_variable_id: event.runtime_variable_id.ok_or_else(|| {
                            RecorderDiagnostic::writer_finalization_failed(format!(
                                "runtime sidecar line {} missing required field runtime_variable_id",
                                line_number + 1
                            ))
                        })?,
                        slot: event.slot.ok_or_else(|| {
                            RecorderDiagnostic::writer_finalization_failed(format!(
                                "runtime sidecar line {} missing required field slot",
                                line_number + 1
                            ))
                        })?,
                        slot_template: require_optional_sidecar_string(
                            event.slot_template,
                            "slot_template",
                            line_number + 1,
                        )?,
                        name: require_optional_sidecar_string(
                            event.name,
                            "name",
                            line_number + 1,
                        )?,
                        value: event.value.unwrap_or(serde_json::Value::Null),
                    });
                }
                "drop_variables" => {
                    trace_events.push(RuntimeTraceEvent::DropVariables {
                        frame_id: event.frame_id.ok_or_else(|| {
                            RecorderDiagnostic::writer_finalization_failed(format!(
                                "runtime sidecar line {} missing required field frame_id",
                                line_number + 1
                            ))
                        })?,
                        variables: event.variables.unwrap_or_default(),
                    });
                }
                "exception_from" => {
                    trace_events.push(RuntimeTraceEvent::Exception {
                        module: require_sidecar_string(&event, "module", line_number + 1)?,
                        function: require_sidecar_string(&event, "function", line_number + 1)?,
                        arity: require_sidecar_u32(&event, "arity", line_number + 1)?,
                        class: event.class.unwrap_or_else(|| "error".to_string()),
                        reason: event.reason.unwrap_or(serde_json::Value::Null),
                        reason_repr: event.reason_repr.unwrap_or_default(),
                    });
                }
                "message_send" | "message_receive" => {
                    trace_events.push(RuntimeTraceEvent::Message {
                        payload: BeamMessagePayload {
                            schema: event
                                .schema
                                .unwrap_or_else(|| "codetracer.beam.message.v1".to_string()),
                            direction: require_optional_sidecar_string(
                                event.direction,
                                "direction",
                                line_number + 1,
                            )?,
                            trace_tag: require_optional_sidecar_string(
                                event.trace_tag,
                                "trace_tag",
                                line_number + 1,
                            )?,
                            tag: require_optional_sidecar_string(
                                event.tag,
                                "tag",
                                line_number + 1,
                            )?,
                            sender_pid: event.sender_pid,
                            sender_thread_id: event.sender_thread_id,
                            recipient_pid: event.recipient_pid,
                            recipient_thread_id: event.recipient_thread_id,
                            message_format: event
                                .message_format
                                .unwrap_or_else(|| "erlang_external_text".to_string()),
                            message_repr: require_optional_sidecar_string(
                                event.message_repr,
                                "message_repr",
                                line_number + 1,
                            )?,
                            message_truncated: event.message_truncated.unwrap_or(false),
                        },
                    });
                }
                _ => {}
            }
        }

        if !(saw_start && saw_switch && saw_exit && delivered) {
            return Err(RecorderDiagnostic::writer_finalization_failed(format!(
                "runtime session did not deliver required lifecycle events: start={saw_start}, switch={saw_switch}, exit={saw_exit}, delivered={delivered}"
            )));
        }

        Ok(RuntimeDelivery {
            delivered,
            root_thread_id,
            root_pid,
            trace_events,
        })
    }
}

fn require_optional_sidecar_string(
    value: Option<String>,
    field: &str,
    line_number: usize,
) -> Result<String, RecorderDiagnostic> {
    value.ok_or_else(|| {
        RecorderDiagnostic::writer_finalization_failed(format!(
            "runtime sidecar line {line_number} missing required field {field}"
        ))
    })
}

fn require_sidecar_string(
    event: &RuntimeSidecarEvent,
    field: &str,
    line_number: usize,
) -> Result<String, RecorderDiagnostic> {
    let value = match field {
        "module" => event.module.clone(),
        "function" => event.function.clone(),
        _ => None,
    };
    value.ok_or_else(|| {
        RecorderDiagnostic::writer_finalization_failed(format!(
            "runtime sidecar line {line_number} missing required field {field}"
        ))
    })
}

fn require_sidecar_u32(
    event: &RuntimeSidecarEvent,
    field: &str,
    line_number: usize,
) -> Result<u32, RecorderDiagnostic> {
    let value = match field {
        "arity" => event.arity,
        _ => None,
    };
    value.ok_or_else(|| {
        RecorderDiagnostic::writer_finalization_failed(format!(
            "runtime sidecar line {line_number} missing required field {field}"
        ))
    })
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct FunctionKey {
    module: String,
    function: String,
    arity: u32,
    kind: String,
    defining_path: PathBuf,
    defining_line: i64,
}

struct FunctionInterner {
    specs: HashMap<(String, String, u32), TraceFunctionSpec>,
    ids: HashMap<FunctionKey, FunctionId>,
}

impl FunctionInterner {
    fn new(functions: &[TraceFunctionSpec]) -> Self {
        let specs = functions
            .iter()
            .cloned()
            .map(|function| {
                (
                    (
                        function.module.clone(),
                        function.function.clone(),
                        function.arity,
                    ),
                    function,
                )
            })
            .collect();
        Self {
            specs,
            ids: HashMap::new(),
        }
    }

    fn ensure_id(
        &mut self,
        writer: &mut NimTraceWriter,
        module: &str,
        function: &str,
        arity: u32,
        source_root: &Path,
        runtime_location: Option<&ResolvedSourceLocation>,
    ) -> FunctionId {
        let spec = self
            .specs
            .get(&(module.to_string(), function.to_string(), arity))
            .cloned()
            .unwrap_or_else(|| TraceFunctionSpec {
                module: module.to_string(),
                function: function.to_string(),
                arity,
                kind: "beam".to_string(),
                source_path: source_root.join("<unknown>"),
                line: 1,
                manifest_id: "unknown".to_string(),
                function_key: format!("{module}.{function}/{arity}"),
                location_id: 0,
                clause_id: 0,
                resolved_source_path: runtime_location
                    .map(|location| PathBuf::from(&location.build_path))
                    .unwrap_or_else(|| source_root.join("<unknown>")),
                resolved_line: runtime_location.map(|location| location.line).unwrap_or(1),
                resolved_column: runtime_location.and_then(|location| location.column),
                resolution_strategy: runtime_location
                    .map(|location| location.resolution.clone())
                    .unwrap_or_else(|| "unknown_generated_fallback".to_string()),
                trace_copy_path: runtime_location
                    .map(|location| location.trace_copy_path.clone())
                    .unwrap_or_else(|| "generated/<unknown>".to_string()),
            });
        let key = FunctionKey {
            module: spec.module.clone(),
            function: spec.function.clone(),
            arity: spec.arity,
            kind: spec.kind.clone(),
            defining_path: spec.resolved_source_path.clone(),
            defining_line: spec.resolved_line,
        };
        if let Some(id) = self.ids.get(&key) {
            return *id;
        }

        let display_name = function_display_name(&spec);
        let id = writer.ensure_function_id(
            &display_name,
            &spec.resolved_source_path,
            Line(spec.resolved_line),
        );
        self.ids.insert(key, id);
        id
    }
}

fn function_display_name(function: &TraceFunctionSpec) -> String {
    let module = if function.kind == "elixir" {
        function
            .module
            .strip_prefix("Elixir.")
            .unwrap_or(&function.module)
            .to_string()
    } else {
        function.module.clone()
    };
    let separator = if function.kind == "erlang" { ":" } else { "." };
    format!(
        "{module}{separator}{name}/{arity}",
        name = function.function,
        arity = function.arity
    )
}

fn json_to_trace_value(writer: &mut NimTraceWriter, value: &serde_json::Value) -> ValueRecord {
    json_to_trace_value_with(value, &mut |kind, lang_type, _specific_info| {
        writer.ensure_type_id(kind, lang_type)
    })
    .unwrap_or_else(|error| {
        let type_id = writer.ensure_type_id(TypeKind::Error, "beam_encoder_error");
        ValueRecord::Error {
            msg: error,
            type_id,
        }
    })
}

fn json_to_low_level_trace_value(
    value: &serde_json::Value,
    type_records: &mut Vec<TypeRecord>,
    type_ids: &mut BTreeMap<String, TypeId>,
    events: &mut Vec<TraceLowLevelEvent>,
) -> Result<ValueRecord, String> {
    json_to_trace_value_with(value, &mut |kind, lang_type, specific_info| {
        ensure_low_level_type(
            kind,
            lang_type,
            specific_info,
            type_records,
            type_ids,
            events,
        )
    })
}

fn json_to_trace_value_with<F>(
    value: &serde_json::Value,
    ensure_type: &mut F,
) -> Result<ValueRecord, String>
where
    F: FnMut(TypeKind, &str, TypeSpecificInfo) -> TypeId,
{
    let Some(object) = value.as_object() else {
        let type_id = ensure_type(TypeKind::Raw, "term", TypeSpecificInfo::None);
        return Ok(ValueRecord::Raw {
            r: value.to_string(),
            type_id,
        });
    };
    if object
        .get("ct_value_schema")
        .and_then(serde_json::Value::as_str)
        != Some("codetracer.beam.value.v1")
    {
        let type_id = ensure_type(TypeKind::Raw, "term", TypeSpecificInfo::None);
        return Ok(ValueRecord::Raw {
            r: value.to_string(),
            type_id,
        });
    }

    let kind = object
        .get("kind")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "beam value missing kind".to_string())?;
    let lang_type = object
        .get("lang_type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("term");
    let type_kind = object
        .get("type_kind")
        .and_then(serde_json::Value::as_str)
        .and_then(type_kind_from_name)
        .unwrap_or(TypeKind::Raw);

    match kind {
        "int" => {
            let type_id = ensure_type(TypeKind::Int, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Int {
                i: object
                    .get("value")
                    .and_then(serde_json::Value::as_i64)
                    .ok_or_else(|| "beam int missing i64 value".to_string())?,
                type_id,
            })
        }
        "bigint" => {
            let type_id = ensure_type(TypeKind::Int, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::BigInt {
                b: decode_hex(
                    object
                        .get("bytes_hex")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or(""),
                )?,
                negative: object
                    .get("negative")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
                type_id,
            })
        }
        "float" => {
            let type_id = ensure_type(TypeKind::Float, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Float {
                f: object
                    .get("value")
                    .and_then(serde_json::Value::as_f64)
                    .ok_or_else(|| "beam float missing f64 value".to_string())?,
                type_id,
            })
        }
        "bool" => {
            let type_id = ensure_type(TypeKind::Bool, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Bool {
                b: object
                    .get("value")
                    .and_then(serde_json::Value::as_bool)
                    .ok_or_else(|| "beam bool missing bool value".to_string())?,
                type_id,
            })
        }
        "none" => {
            let type_id = ensure_type(TypeKind::None, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::None { type_id })
        }
        "string" => {
            let type_id = ensure_type(TypeKind::String, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::String {
                text: object
                    .get("value")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                type_id,
            })
        }
        "list" => {
            let elements = object
                .get("elements")
                .and_then(serde_json::Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .map(|value| json_to_trace_value_with(value, ensure_type))
                        .collect::<Result<Vec<_>, _>>()
                })
                .transpose()?
                .unwrap_or_default();
            let type_id = ensure_type(TypeKind::Seq, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Sequence {
                elements,
                is_slice: false,
                type_id,
            })
        }
        "tuple" => {
            let elements = object
                .get("elements")
                .and_then(serde_json::Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .map(|value| json_to_trace_value_with(value, ensure_type))
                        .collect::<Result<Vec<_>, _>>()
                })
                .transpose()?
                .unwrap_or_default();
            let type_id = ensure_type(TypeKind::Tuple, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Tuple { elements, type_id })
        }
        "map_struct" | "record" => {
            let mut field_values = Vec::new();
            let mut field_types = Vec::new();
            for field in object
                .get("fields")
                .and_then(serde_json::Value::as_array)
                .into_iter()
                .flatten()
            {
                let name = field
                    .get("name")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("<field>")
                    .to_string();
                let value = json_to_trace_value_with(
                    field
                        .get("value")
                        .ok_or_else(|| "beam struct field missing value".to_string())?,
                    ensure_type,
                )?;
                field_types.push(FieldTypeRecord {
                    name,
                    type_id: value_type_id(&value).unwrap_or(TypeId(0)),
                });
                field_values.push(value);
            }
            let type_id = ensure_type(
                TypeKind::Struct,
                lang_type,
                TypeSpecificInfo::Struct {
                    fields: field_types,
                },
            );
            Ok(ValueRecord::Struct {
                field_values,
                type_id,
            })
        }
        "truncated" => {
            let type_id = ensure_type(TypeKind::NonExpanded, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Raw {
                r: object
                    .get("value")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("[truncated]")
                    .to_string(),
                type_id,
            })
        }
        "raw" | "atom" => {
            let type_id = ensure_type(type_kind, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Raw {
                r: object
                    .get("value")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                type_id,
            })
        }
        other => {
            let type_id = ensure_type(TypeKind::Raw, lang_type, TypeSpecificInfo::None);
            Ok(ValueRecord::Raw {
                r: format!("[unsupported beam value kind {other}]"),
                type_id,
            })
        }
    }
}

fn value_type_id(value: &ValueRecord) -> Option<TypeId> {
    match value {
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
        | ValueRecord::Char { type_id, .. } => Some(*type_id),
        ValueRecord::Cell { .. } => None,
    }
}

fn type_kind_from_name(name: &str) -> Option<TypeKind> {
    match name {
        "Seq" => Some(TypeKind::Seq),
        "Set" => Some(TypeKind::Set),
        "Array" => Some(TypeKind::Array),
        "Struct" => Some(TypeKind::Struct),
        "Int" => Some(TypeKind::Int),
        "Float" => Some(TypeKind::Float),
        "String" => Some(TypeKind::String),
        "Char" => Some(TypeKind::Char),
        "Bool" => Some(TypeKind::Bool),
        "Ref" => Some(TypeKind::Ref),
        "Raw" => Some(TypeKind::Raw),
        "TableKind" => Some(TypeKind::TableKind),
        "FunctionKind" => Some(TypeKind::FunctionKind),
        "Tuple" => Some(TypeKind::Tuple),
        "None" => Some(TypeKind::None),
        "NonExpanded" => Some(TypeKind::NonExpanded),
        "Error" => Some(TypeKind::Error),
        "Any" => Some(TypeKind::Any),
        _ => None,
    }
}

fn decode_hex(text: &str) -> Result<Vec<u8>, String> {
    if !text.len().is_multiple_of(2) {
        return Err("hex string has odd length".to_string());
    }
    (0..text.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&text[index..index + 2], 16)
                .map_err(|error| format!("invalid hex byte: {error}"))
        })
        .collect()
}

fn is_beam_target(target_command: &str) -> bool {
    matches!(
        target_program_name(target_command).as_str(),
        "mix" | "erl" | "rebar3"
    )
}

#[derive(Clone, Copy)]
enum RuntimeCompiler {
    Erlc,
    Elixir,
}

fn compile_runtime_app(out_dir: &Path, target_command: &str) -> Result<PathBuf, Box<dyn Error>> {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let src_dir = repo_root.join("apps/codetracer_erlang_runtime/src");
    let build_dir = out_dir.join("runtime").join(RUNTIME_APP_NAME);
    let ebin_dir = build_dir.join("ebin");
    fs::create_dir_all(&ebin_dir)?;
    let compiler = if target_program_name(target_command) == "mix" {
        RuntimeCompiler::Elixir
    } else {
        RuntimeCompiler::Erlc
    };

    for module in [
        "codetracer_erlang_runtime.erl",
        "codetracer_session.erl",
        "codetracer_forms.erl",
        "codetracer_value_encoder.erl",
    ] {
        let source = src_dir.join(module);
        let output = compile_erlang_runtime_source(&source, &ebin_dir, compiler)?;
        if !output.status.success() {
            return Err(format!(
                "runtime compile {} failed with status {:?}\n{}{}",
                source.display(),
                output.status.code(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            )
            .into());
        }
    }

    fs::copy(
        src_dir.join(format!("{RUNTIME_APP_NAME}.app.src")),
        ebin_dir.join(format!("{RUNTIME_APP_NAME}.app")),
    )?;
    Ok(ebin_dir)
}

fn compile_erlang_runtime_source(
    source: &Path,
    ebin_dir: &Path,
    compiler: RuntimeCompiler,
) -> io::Result<std::process::Output> {
    match compiler {
        RuntimeCompiler::Erlc => Command::new("erlc")
            .arg("+debug_info")
            .arg("-o")
            .arg(ebin_dir)
            .arg(source)
            .output(),
        RuntimeCompiler::Elixir => Command::new("elixir")
            .arg("-e")
            .arg(format!(
                "case :compile.file({source}, [:debug_info, {{:outdir, {outdir}}}]) do {{:ok, _}} -> :ok; other -> raise inspect(other) end",
                source = elixir_charlist(&source.display().to_string()),
                outdir = elixir_charlist(&ebin_dir.display().to_string())
            ))
            .output(),
    }
}

fn discover_source_paths(source_root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for dirname in ["lib", "src", "test"] {
        let dir = source_root.join(dirname);
        if dir.is_dir() {
            collect_source_paths(&dir, &mut paths)?;
        }
    }
    for filename in ["mix.exs", "rebar.config", "Makefile"] {
        let file = source_root.join(filename);
        if file.is_file() {
            paths.push(file);
        }
    }
    paths.sort();
    paths.dedup();
    Ok(paths)
}

fn collect_source_paths(dir: &Path, paths: &mut Vec<PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_source_paths(&path, paths)?;
        } else if is_source_file(&path) {
            paths.push(path);
        }
    }
    Ok(())
}

fn discover_source_maps(source_root: &Path) -> io::Result<Vec<SparseSourceMap>> {
    let mut paths = Vec::new();
    for dirname in ["source_maps", "codetracer_source_maps"] {
        let dir = source_root.join(dirname);
        if dir.is_dir() {
            collect_json_paths(&dir, &mut paths)?;
        }
    }

    let mut source_maps = Vec::new();
    for path in paths {
        let text = fs::read_to_string(&path)?;
        let mut map: SparseSourceMap = serde_json::from_str(&text).map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid source map {}: {error}", path.display()),
            )
        })?;
        if map.schema != "codetracer.beam.sourcemap.v1" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "unsupported source map schema {} in {}",
                    map.schema,
                    path.display()
                ),
            ));
        }
        map.generated_path =
            normalize_build_path(&resolve_mapped_path(source_root, &map.generated_path))
                .display()
                .to_string();
        map.original_path =
            normalize_build_path(&resolve_mapped_path(source_root, &map.original_path))
                .display()
                .to_string();
        source_maps.push(map);
    }
    source_maps.sort_by(|left, right| {
        (&left.generated_path, &left.original_path)
            .cmp(&(&right.generated_path, &right.original_path))
    });
    Ok(source_maps)
}

fn collect_json_paths(dir: &Path, paths: &mut Vec<PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_json_paths(&path, paths)?;
        } else if path.extension().and_then(|extension| extension.to_str()) == Some("json") {
            paths.push(path);
        }
    }
    Ok(())
}

fn instrument_erlang_sources(
    out_dir: &Path,
    source_root: &Path,
    source_paths: &[PathBuf],
    runtime_ebin: &Path,
    source_maps: &[SparseSourceMap],
) -> Result<InstrumentationArtifacts, Box<dyn Error>> {
    let erlang_sources = source_paths
        .iter()
        .filter(|path| path.extension().and_then(|extension| extension.to_str()) == Some("erl"))
        .collect::<Vec<_>>();
    if erlang_sources.is_empty() {
        return Ok(InstrumentationArtifacts {
            ebin_dir: None,
            locations: Vec::new(),
            variable_slot_templates: Vec::new(),
            dumps: Vec::new(),
        });
    }

    let instrumented_root = out_dir.join("instrumented");
    let ebin_dir = instrumented_root.join("ebin");
    let locations_root = out_dir.join("recorder_metadata").join("step_locations");
    let dumps_root = out_dir.join("recorder_metadata").join("transformed_forms");
    fs::create_dir_all(&ebin_dir)?;
    fs::create_dir_all(&locations_root)?;
    fs::create_dir_all(&dumps_root)?;

    let mut locations = Vec::new();
    let mut variable_slot_templates = Vec::new();
    let mut dumps = Vec::new();

    for source_path in erlang_sources {
        let source_path = normalize_build_path(source_path);
        let relative = project_relative_path(source_root, &source_path);
        let safe = safe_filename(&relative.replace(['/', '\\'], "_"));
        let locations_path = locations_root.join(format!("{safe}.step-locations.json"));
        let dump_path = dumps_root.join(format!("{safe}.transformed.erl"));
        run_forms_instrumenter(
            runtime_ebin,
            &source_path,
            &ebin_dir,
            &locations_path,
            &dump_path,
        )?;

        let text = fs::read_to_string(&locations_path)?;
        let parsed: StepLocationsFile = serde_json::from_str(&text)?;
        if parsed.schema != "codetracer.beam.step-locations.v1" {
            return Err(format!(
                "unsupported step location schema {} in {}",
                parsed.schema,
                locations_path.display()
            )
            .into());
        }
        let parsed_source = normalize_build_path(Path::new(&parsed.source_path));
        if parsed_source != source_path {
            return Err(format!(
                "instrumenter reported source {} for {}",
                parsed.source_path,
                source_path.display()
            )
            .into());
        }

        variable_slot_templates.extend(parsed.variable_slot_templates.into_iter().map(|slot| {
            ManifestVariableSlotTemplate {
                function_key: slot.function_key,
                slot: slot.slot,
                name: slot.name,
                source: slot.source,
            }
        }));

        for raw in parsed.locations {
            let raw_source = normalize_build_path(Path::new(&raw.source_path));
            let resolved = resolve_source_location(
                source_root,
                source_maps,
                &raw_source,
                raw.line,
                raw.column,
            );
            locations.push(TraceLocationSpec {
                module: parsed.module.clone(),
                source_path: raw_source,
                location_id: raw.id,
                resolved_source_path: PathBuf::from(&resolved.build_path),
                resolved_line: resolved.line,
                resolved_column: resolved.column,
                resolution_strategy: resolved.resolution,
                trace_copy_path: resolved.trace_copy_path,
                generated: raw.generated,
            });
        }

        dumps.push(TransformedFormsDump {
            module: parsed.module,
            format: "erl_pp:form/1 pretty-printed Erlang source".to_string(),
            build_path: dump_path.display().to_string(),
            trace_copy_path: format!(
                "recorder_metadata/transformed_forms/{}",
                dump_path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("transformed.erl")
            ),
            runtime_path: dump_path.display().to_string(),
        });
    }

    locations.sort_by(|left, right| {
        (
            &left.module,
            &left.source_path,
            left.resolved_line,
            left.resolved_column,
            left.location_id,
        )
            .cmp(&(
                &right.module,
                &right.source_path,
                right.resolved_line,
                right.resolved_column,
                right.location_id,
            ))
    });
    locations.dedup_by_key(|location| location.location_id);
    variable_slot_templates.sort_by(|left, right| {
        (&left.function_key, left.slot, &left.name).cmp(&(
            &right.function_key,
            right.slot,
            &right.name,
        ))
    });
    variable_slot_templates
        .dedup_by(|left, right| left.function_key == right.function_key && left.slot == right.slot);

    Ok(InstrumentationArtifacts {
        ebin_dir: Some(ebin_dir),
        locations,
        variable_slot_templates,
        dumps,
    })
}

fn run_forms_instrumenter(
    runtime_ebin: &Path,
    source_path: &Path,
    ebin_dir: &Path,
    locations_path: &Path,
    dump_path: &Path,
) -> Result<(), Box<dyn Error>> {
    let expression = format!(
        "case codetracer_forms:instrument_file({source}, {out_dir}, {locations}, {dump}) of ok -> halt(0); {{error, Reason}} -> io:format(standard_error, \"~tp~n\", [Reason]), halt(1) end.",
        source = erlang_string(&source_path.display().to_string()),
        out_dir = erlang_string(&ebin_dir.display().to_string()),
        locations = erlang_string(&locations_path.display().to_string()),
        dump = erlang_string(&dump_path.display().to_string())
    );
    let output = Command::new("erl")
        .args(["-noshell", "-pa"])
        .arg(runtime_ebin)
        .arg("-eval")
        .arg(expression)
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "abstract-forms instrumentation failed for {} with status {:?}\n{}{}",
            source_path.display(),
            output.status.code(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
        .into())
    }
}

fn write_recorder_metadata(
    out_dir: &Path,
    source_root: &Path,
    trace_functions: &[TraceFunctionSpec],
    step_locations: &[TraceLocationSpec],
    variable_slot_templates: &[ManifestVariableSlotTemplate],
    source_maps: &[SparseSourceMap],
    transformed_form_dumps: &[TransformedFormsDump],
) -> Result<(Vec<ManifestArtifact>, Vec<SourceMapArtifact>), Box<dyn Error>> {
    let metadata_root = out_dir.join("recorder_metadata");
    let manifests_root = metadata_root.join("manifests");
    let source_maps_root = metadata_root.join("source_maps");
    fs::create_dir_all(&manifests_root)?;
    fs::create_dir_all(&source_maps_root)?;

    let source_map_artifacts =
        write_source_map_artifacts(source_root, &source_maps_root, source_maps)?;
    let manifest_artifacts = write_module_manifests(
        source_root,
        &manifests_root,
        trace_functions,
        step_locations,
        variable_slot_templates,
        &source_map_artifacts,
    )?;
    for dump in transformed_form_dumps {
        if !Path::new(&dump.runtime_path).is_file() {
            return Err(format!("missing transformed-forms dump {}", dump.runtime_path).into());
        }
    }

    Ok((manifest_artifacts, source_map_artifacts))
}

fn write_source_map_artifacts(
    source_root: &Path,
    source_maps_root: &Path,
    source_maps: &[SparseSourceMap],
) -> Result<Vec<SourceMapArtifact>, Box<dyn Error>> {
    let mut artifacts = Vec::new();
    for (index, source_map) in source_maps.iter().enumerate() {
        let filename = format!(
            "{:03}-{}.json",
            index + 1,
            safe_filename(&project_relative_path(
                source_root,
                Path::new(&source_map.generated_path)
            ))
        );
        let trace_copy_path = format!("recorder_metadata/source_maps/{filename}");
        let destination = source_maps_root.join(filename);
        let json = serde_json::to_vec_pretty(source_map)?;
        fs::write(&destination, json)?;
        artifacts.push(SourceMapArtifact {
            source_language: source_map.source_language.clone(),
            generated_build_path: source_map.generated_path.clone(),
            original_build_path: source_map.original_path.clone(),
            trace_copy_path,
        });
    }
    Ok(artifacts)
}

fn write_module_manifests(
    source_root: &Path,
    manifests_root: &Path,
    trace_functions: &[TraceFunctionSpec],
    step_locations: &[TraceLocationSpec],
    variable_slot_templates: &[ManifestVariableSlotTemplate],
    source_maps: &[SourceMapArtifact],
) -> Result<Vec<ManifestArtifact>, Box<dyn Error>> {
    let mut by_module: BTreeMap<String, Vec<TraceFunctionSpec>> = BTreeMap::new();
    for function in trace_functions {
        by_module
            .entry(function.module.clone())
            .or_default()
            .push(function.clone());
    }

    let mut artifacts = Vec::new();
    for (module, mut functions) in by_module {
        functions.sort_by(|left, right| {
            (&left.function, left.arity, left.line).cmp(&(&right.function, right.arity, right.line))
        });
        let first = functions
            .first()
            .ok_or_else(|| format!("module {module} has no functions"))?;
        let build_path = first.source_path.display().to_string();
        let project_relative = project_relative_path(source_root, &first.source_path);
        let trace_copy = trace_copy_path(source_root, &first.source_path);
        let manifest_id = manifest_id_for_module(&module);
        let source_language = first.kind.clone();
        let module_step_locations = step_locations
            .iter()
            .filter(|location| location.module == module)
            .collect::<Vec<_>>();
        let mut manifest_locations = BTreeMap::new();
        for function in &functions {
            manifest_locations.insert(
                function.location_id,
                ManifestLocation {
                    id: function.location_id,
                    build_path: function.resolved_source_path.display().to_string(),
                    project_relative_path: project_relative_path(
                        source_root,
                        &function.resolved_source_path,
                    ),
                    trace_copy_path: function.trace_copy_path.clone(),
                    line: function.resolved_line,
                    column: function.resolved_column,
                    resolution: function.resolution_strategy.clone(),
                },
            );
        }
        for location in &module_step_locations {
            manifest_locations.insert(
                location.location_id,
                ManifestLocation {
                    id: location.location_id,
                    build_path: location.resolved_source_path.display().to_string(),
                    project_relative_path: project_relative_path(
                        source_root,
                        &location.resolved_source_path,
                    ),
                    trace_copy_path: location.trace_copy_path.clone(),
                    line: location.resolved_line,
                    column: location.resolved_column,
                    resolution: location.resolution_strategy.clone(),
                },
            );
        }
        let function_keys = functions
            .iter()
            .map(|function| function.function_key.clone())
            .collect::<std::collections::HashSet<_>>();
        let mut slots = functions
            .iter()
            .flat_map(|function| {
                (0..function.arity).map(|slot| ManifestVariableSlotTemplate {
                    function_key: function.function_key.clone(),
                    slot,
                    name: format!("_arg{slot}"),
                    source: "runtime_call_arg".to_string(),
                })
            })
            .collect::<Vec<_>>();
        slots.extend(
            variable_slot_templates
                .iter()
                .filter(|slot| function_keys.contains(&slot.function_key))
                .cloned(),
        );
        slots.sort_by(|left, right| {
            (&left.function_key, left.slot, &left.name).cmp(&(
                &right.function_key,
                right.slot,
                &right.name,
            ))
        });
        slots.dedup_by(|left, right| {
            left.function_key == right.function_key && left.slot == right.slot
        });

        let manifest = ModuleManifest {
            schema: "codetracer.beam.module-manifest.v1".to_string(),
            encoding: "json".to_string(),
            manifest_id: manifest_id.clone(),
            module: ManifestModuleIdentity {
                name: module.clone(),
                source_language,
                build_path: build_path.clone(),
                project_relative_path: project_relative.clone(),
                trace_copy_path: trace_copy.clone(),
            },
            functions: functions
                .iter()
                .map(|function| ManifestFunction {
                    key: function.function_key.clone(),
                    name: function.function.clone(),
                    arity: function.arity,
                    visibility: "unknown".to_string(),
                    location_id: function.location_id,
                    clause_ids: vec![function.clause_id],
                    traceable: true,
                })
                .collect(),
            locations: manifest_locations.into_values().collect(),
            clauses: functions
                .iter()
                .map(|function| ManifestClause {
                    id: function.clause_id,
                    function_key: function.function_key.clone(),
                    location_id: function.location_id,
                })
                .collect(),
            variable_slot_templates: slots,
            traceable_mfas: functions
                .iter()
                .map(|function| ManifestMfa {
                    module: function.module.clone(),
                    function: function.function.clone(),
                    arity: function.arity,
                })
                .collect(),
            source_maps: source_maps
                .iter()
                .filter(|source_map| {
                    functions.iter().any(|function| {
                        source_map.generated_build_path
                            == function.source_path.display().to_string()
                    }) || module_step_locations.iter().any(|location| {
                        source_map.generated_build_path
                            == location.source_path.display().to_string()
                    })
                })
                .map(|source_map| source_map.trace_copy_path.clone())
                .collect(),
        };

        let reparsed = decode_manifest_json(&encode_manifest_json(&manifest)?)?;
        if reparsed.schema != manifest.schema || reparsed.manifest_id != manifest.manifest_id {
            return Err(format!("manifest JSON roundtrip failed for module {module}").into());
        }

        let filename = format!("{}.manifest.json", safe_filename(&module));
        let trace_copy_path = format!("recorder_metadata/manifests/{filename}");
        let destination = manifests_root.join(filename);
        fs::write(&destination, encode_manifest_json(&manifest)?)?;
        artifacts.push(ManifestArtifact {
            module,
            manifest_id,
            encoding: "json".to_string(),
            schema: "codetracer.beam.module-manifest.v1".to_string(),
            build_path,
            trace_copy_path,
            runtime_path: destination.display().to_string(),
        });
    }
    Ok(artifacts)
}

fn encode_manifest_json(manifest: &ModuleManifest) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec_pretty(manifest)
}

fn decode_manifest_json(bytes: &[u8]) -> Result<ModuleManifest, serde_json::Error> {
    serde_json::from_slice(bytes)
}

fn safe_filename(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' || ch == '.' {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

fn discover_trace_functions(
    source_root: &Path,
    source_paths: &[PathBuf],
    source_maps: &[SparseSourceMap],
) -> io::Result<Vec<TraceFunctionSpec>> {
    let mut functions = Vec::new();
    for source_path in source_paths {
        match source_path
            .extension()
            .and_then(|extension| extension.to_str())
        {
            Some("ex" | "exs") => collect_elixir_trace_functions(
                source_root,
                source_maps,
                source_path,
                &mut functions,
            )?,
            Some("erl") => collect_erlang_trace_functions(
                source_root,
                source_maps,
                source_path,
                &mut functions,
            )?,
            _ => {}
        }
    }
    functions.sort_by(|left, right| {
        (
            &left.module,
            &left.function,
            left.arity,
            &left.source_path,
            left.line,
        )
            .cmp(&(
                &right.module,
                &right.function,
                right.arity,
                &right.source_path,
                right.line,
            ))
    });
    functions.dedup_by(|left, right| {
        left.module == right.module
            && left.function == right.function
            && left.arity == right.arity
            && left.source_path == right.source_path
            && left.line == right.line
    });
    Ok(functions)
}

fn collect_elixir_trace_functions(
    source_root: &Path,
    source_maps: &[SparseSourceMap],
    source_path: &Path,
    functions: &mut Vec<TraceFunctionSpec>,
) -> io::Result<()> {
    let text = fs::read_to_string(source_path)?;
    let mut module = None;

    for (index, line) in text.lines().enumerate() {
        let trimmed = line.trim_start();
        if module.is_none() {
            if let Some(name) = trimmed.strip_prefix("defmodule ") {
                module = Some(format!("Elixir.{}", take_identifier(name)));
            }
        }

        for prefix in ["def ", "defp "] {
            if let Some(rest) = trimmed.strip_prefix(prefix) {
                let Some(module) = &module else {
                    continue;
                };
                let function = take_identifier(rest).trim_start_matches(':').to_string();
                if function.is_empty() || function == "module" {
                    continue;
                }
                let arity = arity_from_elixir_def(rest);
                functions.push(trace_function_spec(TraceFunctionInput {
                    source_root,
                    source_maps,
                    module,
                    function: &function,
                    arity,
                    kind: "elixir",
                    source_path,
                    line: (index + 1) as i64,
                }));
            }
        }
    }

    Ok(())
}

fn collect_erlang_trace_functions(
    source_root: &Path,
    source_maps: &[SparseSourceMap],
    source_path: &Path,
    functions: &mut Vec<TraceFunctionSpec>,
) -> io::Result<()> {
    let text = fs::read_to_string(source_path)?;
    let mut module = None;

    for (index, line) in text.lines().enumerate() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("-module(") {
            module = rest
                .split_once(')')
                .map(|(name, _)| name.trim().trim_matches('\'').to_string());
            continue;
        }
        if trimmed.starts_with('%') || trimmed.starts_with('-') || !trimmed.contains("->") {
            continue;
        }
        let Some((name, rest)) = trimmed.split_once('(') else {
            continue;
        };
        let Some(module) = &module else {
            continue;
        };
        let function = name.trim().trim_matches('\'').to_string();
        if function.is_empty() || !is_erlang_function_name(&function) {
            continue;
        }
        let Some((args, _)) = rest.split_once(')') else {
            continue;
        };
        let arity = arity_from_args(args);
        functions.push(trace_function_spec(TraceFunctionInput {
            source_root,
            source_maps,
            module,
            function: &function,
            arity,
            kind: "erlang",
            source_path,
            line: (index + 1) as i64,
        }));
    }

    Ok(())
}

struct TraceFunctionInput<'a> {
    source_root: &'a Path,
    source_maps: &'a [SparseSourceMap],
    module: &'a str,
    function: &'a str,
    arity: u32,
    kind: &'a str,
    source_path: &'a Path,
    line: i64,
}

fn trace_function_spec(input: TraceFunctionInput<'_>) -> TraceFunctionSpec {
    let TraceFunctionInput {
        source_root,
        source_maps,
        module,
        function,
        arity,
        kind,
        source_path,
        line,
    } = input;
    let source_path = normalize_build_path(source_path);
    let resolved = resolve_source_location(source_root, source_maps, &source_path, line, None);
    let function_key = format!("{module}.{function}/{arity}");
    let location_id = stable_id(&format!("{function_key}:location:{line}"));
    let clause_id = stable_id(&format!("{function_key}:clause:{line}"));

    TraceFunctionSpec {
        module: module.to_string(),
        function: function.to_string(),
        arity,
        kind: kind.to_string(),
        source_path,
        line,
        manifest_id: manifest_id_for_module(module),
        function_key,
        location_id,
        clause_id,
        resolved_source_path: PathBuf::from(&resolved.build_path),
        resolved_line: resolved.line,
        resolved_column: resolved.column,
        resolution_strategy: resolved.resolution,
        trace_copy_path: resolved.trace_copy_path,
    }
}

fn take_identifier(text: &str) -> String {
    text.trim_start()
        .chars()
        .take_while(|ch| {
            ch.is_alphanumeric() || *ch == '_' || *ch == '.' || *ch == ':' || *ch == '!'
        })
        .collect()
}

fn arity_from_elixir_def(text: &str) -> u32 {
    let Some(after_name) = text.split_once('(').map(|(_, rest)| rest) else {
        return 0;
    };
    let Some((args, _)) = after_name.split_once(')') else {
        return 0;
    };
    arity_from_args(args)
}

fn arity_from_args(args: &str) -> u32 {
    let args = args.trim();
    if args.is_empty() {
        0
    } else {
        args.split(',').count() as u32
    }
}

fn is_erlang_function_name(name: &str) -> bool {
    name.chars()
        .next()
        .is_some_and(|ch| ch.is_ascii_lowercase() || ch == '\'')
}

fn is_source_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|extension| extension.to_str()),
        Some("ex" | "exs" | "erl" | "hrl")
    )
}

fn normalize_build_path(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| {
        if path.is_absolute() {
            path.to_path_buf()
        } else {
            env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(path)
        }
    })
}

fn project_relative_path(source_root: &Path, path: &Path) -> String {
    path.strip_prefix(source_root)
        .unwrap_or(path)
        .display()
        .to_string()
}

fn trace_copy_path(source_root: &Path, path: &Path) -> String {
    format!(
        "files/{}",
        project_relative_path(source_root, path).replace('\\', "/")
    )
}

fn manifest_id_for_module(module: &str) -> String {
    format!("beam-manifest-v1:{module}")
}

fn stable_id(text: &str) -> u32 {
    let mut hash = 2_166_136_261_u32;
    for byte in text.as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(16_777_619);
    }
    if hash == 0 {
        1
    } else {
        hash
    }
}

fn resolve_source_location(
    source_root: &Path,
    source_maps: &[SparseSourceMap],
    generated_path: &Path,
    line: i64,
    column: Option<u32>,
) -> ResolvedSourceLocation {
    let generated_build_path = normalize_build_path(generated_path);
    if let Some((map, entry)) = find_source_map_entry(
        source_root,
        source_maps,
        &generated_build_path,
        line,
        column,
    ) {
        let original_path =
            normalize_build_path(&resolve_mapped_path(source_root, &map.original_path));
        return ResolvedSourceLocation {
            build_path: original_path.display().to_string(),
            trace_copy_path: trace_copy_path(source_root, &original_path),
            line: entry.original_line,
            column: entry.original_column,
            resolution: "source_map".to_string(),
        };
    }

    if generated_build_path.is_file() && line > 0 {
        return ResolvedSourceLocation {
            build_path: generated_build_path.display().to_string(),
            trace_copy_path: trace_copy_path(source_root, &generated_build_path),
            line,
            column,
            resolution: "erl_anno".to_string(),
        };
    }

    if generated_build_path.is_file() {
        return ResolvedSourceLocation {
            build_path: generated_build_path.display().to_string(),
            trace_copy_path: trace_copy_path(source_root, &generated_build_path),
            line: 1,
            column: None,
            resolution: "module_file_fallback".to_string(),
        };
    }

    ResolvedSourceLocation {
        build_path: generated_build_path.display().to_string(),
        trace_copy_path: "generated/<unknown>".to_string(),
        line: 1,
        column: None,
        resolution: "unknown_generated_fallback".to_string(),
    }
}

fn find_source_map_entry<'a>(
    source_root: &Path,
    source_maps: &'a [SparseSourceMap],
    generated_path: &Path,
    line: i64,
    column: Option<u32>,
) -> Option<(&'a SparseSourceMap, &'a SparseSourceMapEntry)> {
    source_maps.iter().find_map(|map| {
        let map_generated =
            normalize_build_path(&resolve_mapped_path(source_root, &map.generated_path));
        if map_generated != generated_path {
            return None;
        }
        map.mappings
            .iter()
            .find(|entry| {
                entry.generated_line == line
                    && (entry.generated_column.is_none() || entry.generated_column == column)
            })
            .map(|entry| (map, entry))
    })
}

fn resolve_mapped_path(source_root: &Path, path: &str) -> PathBuf {
    let path = PathBuf::from(path);
    if path.is_absolute() {
        path
    } else {
        source_root.join(path)
    }
}

fn copy_sources(
    out_dir: &Path,
    source_root: &Path,
    source_paths: &[PathBuf],
) -> io::Result<Vec<CopiedSource>> {
    let compatibility_bundle_root = out_dir.join("source_map");
    let files_bundle_root = out_dir.join("files");
    let mut copied = Vec::new();
    for source_path in source_paths {
        let source_path = normalize_build_path(source_path);
        let relative = source_path
            .strip_prefix(source_root)
            .unwrap_or(&source_path);
        let destination = compatibility_bundle_root.join(relative);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&source_path, &destination)?;
        let files_destination = files_bundle_root.join(relative);
        if let Some(parent) = files_destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&source_path, &files_destination)?;
        let project_relative_path = relative.display().to_string();
        let trace_copy_path = format!("files/{}", project_relative_path.replace('\\', "/"));
        copied.push(CopiedSource {
            source_path: source_path.display().to_string(),
            bundle_path: destination.display().to_string(),
            build_path: source_path.display().to_string(),
            project_relative_path,
            trace_copy_path,
        });
    }
    Ok(copied)
}

fn wrap_elixir_expression(expression: &str, runtime: &RuntimeSession) -> String {
    let runtime_ebin = runtime
        .runtime_ebin
        .as_ref()
        .map(|path| elixir_charlist(&path.display().to_string()))
        .unwrap_or_else(|| "~c\"\"".to_string());
    format!(
        ":code.add_patha({runtime_ebin})\n:ok = :codetracer_erlang_runtime.start_session({options})\ntry do\n  {expression}\nafter\n  :ok = :codetracer_erlang_runtime.stop_session(:normal)\nend",
        runtime_ebin = runtime_ebin,
        options = elixir_runtime_options(runtime)
    )
}

fn wrap_erlang_entrypoint(module: &str, function: &str, runtime: &RuntimeSession) -> String {
    format!(
        "codetracer_erlang_runtime:start_session({options}), try apply({module}, {function}, []) of _ -> codetracer_erlang_runtime:stop_session(normal), halt(0) catch Class:Reason:Stack -> codetracer_erlang_runtime:stop_session({{Class,Reason}}), erlang:raise(Class, Reason, Stack) end.",
        options = erlang_runtime_options(runtime),
        module = erlang_atom(module),
        function = erlang_atom(function)
    )
}

fn elixir_runtime_options(runtime: &RuntimeSession) -> String {
    format!(
        "[{{:session_file, {session_file}}}, {{:source_paths, {source_paths}}}, {{:manifest_paths, {manifest_paths}}}, {{:trace_functions, {trace_functions}}}]",
        session_file = elixir_charlist(&runtime.session_file.display().to_string()),
        source_paths = elixir_charlist_list(&runtime.source_paths),
        manifest_paths = elixir_string_list(
            &runtime
                .manifests
                .iter()
                .map(|manifest| manifest.runtime_path.clone())
                .collect::<Vec<_>>()
        ),
        trace_functions = elixir_trace_function_list(&runtime.trace_functions)
    )
}

fn erlang_runtime_options(runtime: &RuntimeSession) -> String {
    format!(
        "[{{session_file,{session_file}}},{{source_paths,{source_paths}}},{{manifest_paths,{manifest_paths}}},{{trace_functions,{trace_functions}}}]",
        session_file = erlang_string(&runtime.session_file.display().to_string()),
        source_paths = erlang_string_list(&runtime.source_paths),
        manifest_paths = erlang_string_vec(
            &runtime
                .manifests
                .iter()
                .map(|manifest| manifest.runtime_path.clone())
                .collect::<Vec<_>>()
        ),
        trace_functions = erlang_trace_function_list(&runtime.trace_functions)
    )
}

fn elixir_charlist_list(paths: &[PathBuf]) -> String {
    let values = paths
        .iter()
        .map(|path| elixir_charlist(&path.display().to_string()))
        .collect::<Vec<_>>();
    format!("[{}]", values.join(", "))
}

fn erlang_string_list(paths: &[PathBuf]) -> String {
    let values = paths
        .iter()
        .map(|path| erlang_string(&path.display().to_string()))
        .collect::<Vec<_>>();
    format!("[{}]", values.join(","))
}

fn elixir_string_list(values: &[String]) -> String {
    let values = values
        .iter()
        .map(|value| elixir_charlist(value))
        .collect::<Vec<_>>();
    format!("[{}]", values.join(", "))
}

fn erlang_string_vec(values: &[String]) -> String {
    let values = values
        .iter()
        .map(|value| erlang_string(value))
        .collect::<Vec<_>>();
    format!("[{}]", values.join(","))
}

fn elixir_trace_function_list(functions: &[TraceFunctionSpec]) -> String {
    let values = functions
        .iter()
        .map(|function| {
            format!(
                "{{{module}, {name}, {arity}, {kind}, {source_path}, {line}, {manifest_id}, {function_key}, {location_id}, {clause_id}, {resolved_source_path}, {resolved_line}, {resolved_column}, {resolution_strategy}, {trace_copy_path}}}",
                module = elixir_atom(&function.module),
                name = elixir_atom(&function.function),
                arity = function.arity,
                kind = elixir_charlist(&function.kind),
                source_path = elixir_charlist(&function.source_path.display().to_string()),
                line = function.line,
                manifest_id = elixir_charlist(&function.manifest_id),
                function_key = elixir_charlist(&function.function_key),
                location_id = function.location_id,
                clause_id = function.clause_id,
                resolved_source_path =
                    elixir_charlist(&function.resolved_source_path.display().to_string()),
                resolved_line = function.resolved_line,
                resolved_column = optional_u32_elixir(function.resolved_column),
                resolution_strategy = elixir_charlist(&function.resolution_strategy),
                trace_copy_path = elixir_charlist(&function.trace_copy_path)
            )
        })
        .collect::<Vec<_>>();
    format!("[{}]", values.join(", "))
}

fn erlang_trace_function_list(functions: &[TraceFunctionSpec]) -> String {
    let values = functions
        .iter()
        .map(|function| {
            format!(
                "{{{module},{name},{arity},{kind},{source_path},{line},{manifest_id},{function_key},{location_id},{clause_id},{resolved_source_path},{resolved_line},{resolved_column},{resolution_strategy},{trace_copy_path}}}",
                module = erlang_atom(&function.module),
                name = erlang_atom(&function.function),
                arity = function.arity,
                kind = erlang_string(&function.kind),
                source_path = erlang_string(&function.source_path.display().to_string()),
                line = function.line,
                manifest_id = erlang_string(&function.manifest_id),
                function_key = erlang_string(&function.function_key),
                location_id = function.location_id,
                clause_id = function.clause_id,
                resolved_source_path = erlang_string(&function.resolved_source_path.display().to_string()),
                resolved_line = function.resolved_line,
                resolved_column = optional_u32_erlang(function.resolved_column),
                resolution_strategy = erlang_string(&function.resolution_strategy),
                trace_copy_path = erlang_string(&function.trace_copy_path)
            )
        })
        .collect::<Vec<_>>();
    format!("[{}]", values.join(","))
}

fn optional_u32_elixir(value: Option<u32>) -> String {
    value
        .map(|value| value.to_string())
        .unwrap_or_else(|| "nil".to_string())
}

fn optional_u32_erlang(value: Option<u32>) -> String {
    value
        .map(|value| value.to_string())
        .unwrap_or_else(|| "undefined".to_string())
}

fn elixir_charlist(value: &str) -> String {
    format!("~c\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn elixir_atom(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
    {
        format!(":{value}")
    } else {
        format!(":\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
    }
}

fn erlang_string(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn erlang_atom(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
    {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\\', "\\\\").replace('\'', "\\'"))
    }
}

fn extract_erl_start_function(args: &mut Vec<String>) -> Option<(String, String)> {
    let mut index = 0;
    while index < args.len() {
        if args[index] == "-s" {
            let module = args.get(index + 1)?.clone();
            let function = args
                .get(index + 2)
                .filter(|value| !value.starts_with('-'))
                .cloned()
                .unwrap_or_else(|| "start".to_string());
            if module != "init" {
                let remove_count = if args
                    .get(index + 2)
                    .is_some_and(|value| !value.starts_with('-'))
                {
                    3
                } else {
                    2
                };
                args.drain(index..index + remove_count);
                return Some((module, function));
            }
        }
        index += 1;
    }
    None
}

fn remove_erl_init_stop(args: &mut Vec<String>) {
    let mut index = 0;
    while index + 2 < args.len() {
        if args[index] == "-s" && args[index + 1] == "init" && args[index + 2] == "stop" {
            args.drain(index..index + 3);
        } else {
            index += 1;
        }
    }
}

fn target_program_name(target_command: &str) -> String {
    Path::new(target_command)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or(target_command)
        .to_string()
}

fn recording_anchor_path(target_command: &str) -> PathBuf {
    let path = PathBuf::from(target_command);
    if path.is_absolute() {
        path
    } else {
        env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

fn panic_payload(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "writer initialization panicked".to_string()
    }
}

#[derive(Serialize)]
struct CompatibilityTraceMeta<'a> {
    language: &'static str,
    recorder: &'static str,
    recorder_version: &'static str,
    format: &'static str,
    subcommand: &'a str,
    target: CompatibilityTarget<'a>,
    artifacts: CompatibilityArtifacts,
    runtime_session: CompatibilityRuntimeSession,
    sources: &'a [CopiedSource],
    manifests: &'a [ManifestArtifact],
    source_maps: &'a [SourceMapArtifact],
    transformed_form_dumps: &'a [TransformedFormsDump],
    metadata_contract: CompatibilityMetadataContract,
}

#[derive(Serialize)]
struct CompatibilityTarget<'a> {
    command: &'a str,
    args: &'a [String],
    argv: &'a [String],
    exit_code: i32,
}

#[derive(Serialize)]
struct CompatibilityArtifacts {
    ctfs: String,
    trace_metadata: &'static str,
    trace_paths: &'static str,
}

#[derive(Serialize)]
struct CompatibilityRuntimeSession {
    mode: &'static str,
    delivered: bool,
    root_thread_id: u64,
    root_pid: Option<String>,
    sidecar: String,
    source_root: String,
    injection_decision: String,
}

#[derive(Serialize)]
struct CompatibilityMetadataContract {
    manifest_schema: &'static str,
    manifest_encoding: &'static str,
    source_map_schema: &'static str,
    source_location_resolver_order: [&'static str; 4],
}

fn write_trace_meta_json(
    session: &RecordingSession,
    runtime_result: &RuntimeDelivery,
    target_exit_code: i32,
) -> Result<(), Box<dyn Error>> {
    let meta = CompatibilityTraceMeta {
        language: "elixir",
        recorder: BINARY_NAME,
        recorder_version: VERSION,
        format: session.options.format.as_str(),
        subcommand: session.subcommand,
        target: CompatibilityTarget {
            command: &session.options.target[0],
            args: &session.options.target[1..],
            argv: &session.options.target,
            exit_code: target_exit_code,
        },
        artifacts: CompatibilityArtifacts {
            ctfs: format!("{}.ct", session.program_name),
            trace_metadata: "trace_metadata.json",
            trace_paths: "trace_paths.json",
        },
        runtime_session: CompatibilityRuntimeSession {
            mode: match session.runtime.mode {
                RuntimeMode::Beam => "beam",
                RuntimeMode::NonBeam => "non_beam",
            },
            delivered: runtime_result.delivered,
            root_thread_id: runtime_result.root_thread_id,
            root_pid: runtime_result.root_pid.clone(),
            sidecar: session.runtime.session_file.display().to_string(),
            source_root: session.runtime.source_root.display().to_string(),
            injection_decision: session.prepared_target.injection_decision.clone(),
        },
        sources: &session.runtime.copied_sources,
        manifests: &session.runtime.manifests,
        source_maps: &session.runtime.source_maps,
        transformed_form_dumps: &session.runtime.transformed_form_dumps,
        metadata_contract: CompatibilityMetadataContract {
            manifest_schema: "codetracer.beam.module-manifest.v1",
            manifest_encoding: "json",
            source_map_schema: "codetracer.beam.sourcemap.v1",
            source_location_resolver_order: [
                "source_map",
                "erl_anno",
                "module_file_fallback",
                "unknown_generated_fallback",
            ],
        },
    };
    let json = serde_json::to_vec_pretty(&meta)?;
    fs::write(session.out_dir.join("trace_meta.json"), json)?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WriterFormat {
    Ctfs,
    Json,
}

impl WriterFormat {
    fn parse(value: &str) -> Result<Self, Box<dyn Error>> {
        match value {
            "ctfs" => Ok(Self::Ctfs),
            "json" => Ok(Self::Json),
            other => {
                Err(format!("unsupported writer format: {other}; expected ctfs or json").into())
            }
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Ctfs => "ctfs",
            Self::Json => "json",
        }
    }
}

#[derive(Debug)]
struct FixtureOptions {
    out_dir: PathBuf,
    format: WriterFormat,
}

fn write_fixture(args: Vec<String>) -> Result<(), Box<dyn Error>> {
    let options = parse_fixture_options(args)?;
    fs::create_dir_all(&options.out_dir)?;

    let summary = match options.format {
        WriterFormat::Ctfs => write_ctfs_fixture(&options.out_dir)?,
        WriterFormat::Json => write_json_fixture(&options.out_dir)?,
    };

    println!("{}", serde_json::to_string(&summary)?);
    Ok(())
}

fn parse_fixture_options(args: Vec<String>) -> Result<FixtureOptions, Box<dyn Error>> {
    let mut out_dir = env::var_os("CODETRACER_ELIXIR_RECORDER_OUT_DIR").map(PathBuf::from);
    let mut format = env::var("CODETRACER_FORMAT")
        .ok()
        .map(|value| WriterFormat::parse(&value))
        .transpose()?;

    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "-o" | "--out-dir" => {
                let Some(value) = iter.next() else {
                    return Err(format!("{arg} requires a directory").into());
                };
                out_dir = Some(PathBuf::from(value));
            }
            "-f" | "--format" => {
                let Some(value) = iter.next() else {
                    return Err(format!("{arg} requires a format").into());
                };
                format = Some(WriterFormat::parse(&value)?);
            }
            other => return Err(format!("unexpected writer-fixture argument: {other}").into()),
        }
    }

    Ok(FixtureOptions {
        out_dir: out_dir.unwrap_or_else(|| PathBuf::from("trace-out")),
        format: format.unwrap_or(WriterFormat::Ctfs),
    })
}

#[derive(Serialize)]
struct FixtureSummary {
    status: &'static str,
    format: &'static str,
    writer: &'static str,
    reader: &'static str,
    trace_path: String,
    program: String,
    workdir: String,
    path_count: u64,
    first_path: String,
    step_count: u64,
    event_count: u64,
    first_step: String,
    diagnostic_event: String,
}

fn write_ctfs_fixture(out_dir: &Path) -> Result<FixtureSummary, Box<dyn Error>> {
    let source_path = fixture_source_path();
    let metadata_path = out_dir.join("trace_metadata.json");
    let events_path = out_dir.join("trace.json");
    let paths_path = out_dir.join("trace_paths.json");

    let mut writer = NimTraceWriter::new(FIXTURE_PROGRAM, NimFormat::Ctfs);
    writer.set_workdir(&env::current_dir()?);
    writer.begin_writing_trace_metadata(&metadata_path)?;
    writer.finish_writing_trace_metadata()?;
    writer.begin_writing_trace_events(&events_path)?;
    writer.begin_writing_trace_paths(&paths_path)?;
    writer.finish_writing_trace_paths()?;
    writer.start(&source_path, Line(1));
    writer.register_step(&source_path, Line(5));
    writer.register_step(&source_path, Line(6));
    writer.register_special_event(EventLogKind::Write, "m2", "ctfs writer bridge fixture");
    writer.finish_writing_trace_events()?;
    writer.write_meta_dat("codetracer-elixir-recorder")?;
    writer.close()?;
    drop(writer);

    let ct_path = out_dir.join(format!("{FIXTURE_PROGRAM}.ct"));
    if !ct_path.is_file() {
        return Err(format!("CTFS writer did not create {}", ct_path.display()).into());
    }

    let reader =
        NimTraceReaderHandle::open(ct_path.to_str().ok_or("trace path is not valid UTF-8")?)?;
    let path_count = reader.path_count();
    let step_count = reader.step_count();
    let event_count = reader.event_count();
    if path_count == 0 || step_count == 0 || event_count == 0 {
        return Err(format!("reader saw path_count={path_count}, step_count={step_count}, event_count={event_count}").into());
    }

    Ok(FixtureSummary {
        status: "ok",
        format: WriterFormat::Ctfs.as_str(),
        writer: "codetracer_trace_writer_nim",
        reader: "codetracer_trace_writer_nim::NimTraceReaderHandle",
        trace_path: ct_path.display().to_string(),
        program: reader.program(),
        workdir: reader.workdir(),
        path_count,
        first_path: reader.path(0)?,
        step_count,
        event_count,
        first_step: reader.step_json(0)?,
        diagnostic_event: decode_nim_event_content(&reader.event_json(0)?),
    })
}

fn write_json_fixture(out_dir: &Path) -> Result<FixtureSummary, Box<dyn Error>> {
    let source_path = fixture_source_path();
    let json_path = out_dir.join("trace.json");
    let mut writer = codetracer_trace_writer::create_trace_writer(
        FIXTURE_PROGRAM,
        &[],
        codetracer_trace_writer::TraceEventsFileFormat::Json,
    );

    RustTraceWriter::begin_writing_trace_metadata(
        writer.as_mut(),
        &out_dir.join("trace_metadata.json"),
    )?;
    RustTraceWriter::finish_writing_trace_metadata(writer.as_mut())?;
    RustTraceWriter::begin_writing_trace_paths(writer.as_mut(), &out_dir.join("trace_paths.json"))?;
    RustTraceWriter::finish_writing_trace_paths(writer.as_mut())?;
    writer.begin_writing_trace_events(&json_path)?;
    RustTraceWriter::start(writer.as_mut(), &source_path, Line(1));
    RustTraceWriter::register_step(writer.as_mut(), &source_path, Line(5));
    RustTraceWriter::register_step(writer.as_mut(), &source_path, Line(6));
    RustTraceWriter::register_special_event(
        writer.as_mut(),
        EventLogKind::Write,
        "m2",
        "json writer bridge fixture",
    );
    writer.finish_writing_trace_events()?;

    let mut reader = create_trace_reader(ReaderFormat::Json);
    let events = reader.load_trace_events(&json_path)?;
    if events.is_empty() {
        return Err("JSON reader returned zero events".into());
    }

    let path_count = events
        .iter()
        .filter(|event| matches!(event, TraceLowLevelEvent::Path(_)))
        .count() as u64;
    let step_count = events
        .iter()
        .filter(|event| matches!(event, TraceLowLevelEvent::Step(_)))
        .count() as u64;
    let event_count = events
        .iter()
        .filter(|event| matches!(event, TraceLowLevelEvent::Event(_)))
        .count() as u64;
    let first_path = events
        .iter()
        .find_map(|event| match event {
            TraceLowLevelEvent::Path(path) => Some(path.display().to_string()),
            _ => None,
        })
        .ok_or("JSON reader did not return a Path event")?;
    let first_step = events
        .iter()
        .find_map(|event| match event {
            TraceLowLevelEvent::Step(step) => serde_json::to_string(step).ok(),
            _ => None,
        })
        .ok_or("JSON reader did not return a Step event")?;
    let diagnostic_event = events
        .iter()
        .find_map(|event| match event {
            TraceLowLevelEvent::Event(event) => serde_json::to_string(event).ok(),
            _ => None,
        })
        .ok_or("JSON reader did not return a diagnostic Event")?;

    Ok(FixtureSummary {
        status: "ok",
        format: WriterFormat::Json.as_str(),
        writer: "codetracer_trace_writer::NonStreamingTraceWriter",
        reader: "codetracer_trace_reader::JsonTraceReader",
        trace_path: json_path.display().to_string(),
        program: FIXTURE_PROGRAM.to_string(),
        workdir: env::current_dir()?.display().to_string(),
        path_count,
        first_path,
        step_count,
        event_count,
        first_step,
        diagnostic_event,
    })
}

fn decode_nim_event_content(event_json: &str) -> String {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(event_json) else {
        return event_json.to_string();
    };
    let Some(bytes) = value.get("data").and_then(|data| data.as_array()) else {
        return event_json.to_string();
    };
    let bytes = bytes
        .iter()
        .filter_map(|byte| byte.as_u64().and_then(|value| u8::try_from(value).ok()))
        .collect::<Vec<_>>();
    String::from_utf8(bytes).unwrap_or_else(|_| event_json.to_string())
}

fn fixture_source_path() -> PathBuf {
    env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(FIXTURE_SOURCE)
}

#[cfg(test)]
mod tests {
    use super::{
        parse_fixture_options, parse_record_options, OutputFormat, ParsedRecordCommand,
        WriterFormat,
    };

    #[test]
    fn parses_target_command_after_separator() {
        let args = [
            "--out-dir",
            "/tmp/trace",
            "--format",
            "json",
            "--",
            "erl",
            "-noshell",
        ]
        .map(String::from);

        let ParsedRecordCommand::Record(options) = parse_record_options(args.to_vec()).unwrap()
        else {
            panic!("expected record options");
        };
        assert_eq!(options.out_dir, std::path::PathBuf::from("/tmp/trace"));
        assert_eq!(options.format, OutputFormat::Json);
        assert_eq!(options.target, vec!["erl", "-noshell"]);
    }

    #[test]
    fn parses_unambiguous_target_without_separator() {
        let args = ["--out-dir", "/tmp/trace", "mix", "run"].map(String::from);

        let ParsedRecordCommand::Record(options) = parse_record_options(args.to_vec()).unwrap()
        else {
            panic!("expected record options");
        };
        assert_eq!(options.format, OutputFormat::Ctfs);
        assert_eq!(options.target, vec!["mix", "run"]);
    }

    #[test]
    fn parses_ctfs_format_and_binary_alias() {
        for (format, expected) in [
            ("ctfs", OutputFormat::Ctfs),
            ("binary", OutputFormat::Binary),
        ] {
            let args = ["--format", format, "sh", "-c", "true"].map(String::from);

            let ParsedRecordCommand::Record(options) = parse_record_options(args.to_vec()).unwrap()
            else {
                panic!("expected record options");
            };
            assert_eq!(options.format, expected);
        }
    }

    #[test]
    fn rejects_record_args_without_target() {
        let args = ["--out-dir", "/tmp/trace", "--format", "json"].map(String::from);

        let error = parse_record_options(args.to_vec()).unwrap_err();
        assert_eq!(error.code, "missing_target");
    }

    #[test]
    fn writer_fixture_defaults_to_ctfs() {
        let options = parse_fixture_options(vec!["--out-dir".into(), "/tmp/trace".into()]).unwrap();

        assert_eq!(options.format, WriterFormat::Ctfs);
    }
}
