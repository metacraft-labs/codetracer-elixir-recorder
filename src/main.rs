use std::env;
use std::error::Error;
use std::fs;
use std::io;
use std::panic;
use std::path::{Path, PathBuf};
use std::process::{self, Command, ExitStatus};

use codetracer_trace_reader::{create_trace_reader, TraceEventsFileFormat as ReaderFormat};
use codetracer_trace_types::{EventLogKind, Line, TraceLowLevelEvent};
use codetracer_trace_writer::trace_writer::TraceWriter as RustTraceWriter;
use codetracer_trace_writer_nim::{
    NimTraceReaderHandle, NimTraceWriter, TraceEventsFileFormat as NimFormat,
};
use serde::Serialize;

const BINARY_NAME: &str = "codetracer-elixir-recorder";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const FIXTURE_PROGRAM: &str = "codetracer_elixir_m2_bridge";
const FIXTURE_SOURCE: &str = "test-programs/elixir/canonical_flow/lib/canonical_flow.ex";

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
            let status = run_target(&options.target)?;
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
    Command::new(&target[0])
        .args(&target[1..])
        .status()
        .map_err(|error| RecorderDiagnostic::target_spawn_failed(&target[0], error))
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
}

impl RecordingSession {
    fn begin(
        subcommand: &'static str,
        options: &RecordOptions,
    ) -> Result<Self, RecorderDiagnostic> {
        let program_name = target_program_name(&options.target[0]);
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
        let source_path = recording_anchor_path(&self.options.target[0]);

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
        self.writer.register_step(&source_path, Line(1));
        self.writer.register_special_event(
            EventLogKind::Write,
            "m3",
            "cli skeleton initialized real target execution",
        );

        Ok(())
    }

    fn finish(&mut self, target_exit_code: i32) -> Result<(), RecorderDiagnostic> {
        self.writer
            .finish_writing_trace_events()
            .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))?;
        self.writer
            .write_meta_dat(BINARY_NAME)
            .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))?;
        self.writer
            .close()
            .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))?;

        write_trace_meta_json(
            &self.out_dir,
            &self.program_name,
            self.subcommand,
            &self.options,
            target_exit_code,
        )
        .map_err(|error| RecorderDiagnostic::writer_finalization_failed(error.to_string()))
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

fn write_trace_meta_json(
    out_dir: &Path,
    program_name: &str,
    subcommand: &str,
    options: &RecordOptions,
    target_exit_code: i32,
) -> Result<(), Box<dyn Error>> {
    let meta = CompatibilityTraceMeta {
        language: "elixir",
        recorder: BINARY_NAME,
        recorder_version: VERSION,
        format: options.format.as_str(),
        subcommand,
        target: CompatibilityTarget {
            command: &options.target[0],
            args: &options.target[1..],
            argv: &options.target,
            exit_code: target_exit_code,
        },
        artifacts: CompatibilityArtifacts {
            ctfs: format!("{program_name}.ct"),
            trace_metadata: "trace_metadata.json",
            trace_paths: "trace_paths.json",
        },
    };
    let json = serde_json::to_vec_pretty(&meta)?;
    fs::write(out_dir.join("trace_meta.json"), json)?;
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
