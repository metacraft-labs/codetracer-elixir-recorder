use std::env;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{self, Command};

use codetracer_trace_reader::{create_trace_reader, TraceEventsFileFormat as ReaderFormat};
use codetracer_trace_types::{EventLogKind, Line, TraceLowLevelEvent};
use codetracer_trace_writer::trace_writer::TraceWriter as RustTraceWriter;
use codetracer_trace_writer_nim::{
    NimTraceReaderHandle, NimTraceWriter, TraceEventsFileFormat as NimFormat,
};
use serde::Serialize;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const FIXTURE_PROGRAM: &str = "codetracer_elixir_m2_bridge";
const FIXTURE_SOURCE: &str = "test-programs/elixir/canonical_flow/lib/canonical_flow.ex";

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();

    if env::var("CODETRACER_ELIXIR_RECORDER_DISABLED").as_deref() == Ok("1") {
        return Err(
            "codetracer-elixir-recorder is disabled by CODETRACER_ELIXIR_RECORDER_DISABLED=1"
                .into(),
        );
    }

    if args.is_empty() {
        print_help();
        return Ok(());
    }

    match args.remove(0).as_str() {
        "-h" | "--help" => print_help(),
        "-V" | "--version" | "version" => println!("codetracer-elixir-recorder {VERSION}"),
        "record" => pass_through_target(args)?,
        "writer-fixture" => write_fixture(args)?,
        "instrument" | "compile" => {
            return Err("recorder behavior is not implemented before M3".into())
        }
        command => {
            print_help();
            return Err(format!("unknown command: {command}").into());
        }
    }

    Ok(())
}

fn print_help() {
    println!(
        "codetracer-elixir-recorder {VERSION}

Usage:
  codetracer-elixir-recorder record [--out-dir DIR] [--format FORMAT] -- COMMAND [ARGS...]
  codetracer-elixir-recorder instrument
  codetracer-elixir-recorder compile
  codetracer-elixir-recorder version

Options:
  -o, --out-dir DIR     Output directory for trace files
  -f, --format FORMAT   Trace format: ctfs or json
  -h, --help            Show this help text
  -V, --version         Show recorder version

Environment:
  CODETRACER_ELIXIR_RECORDER_OUT_DIR
  CODETRACER_FORMAT
  CODETRACER_ELIXIR_RECORDER_DISABLED"
    );
}

fn pass_through_target(args: Vec<String>) -> Result<(), Box<dyn Error>> {
    let target_start = target_command_start(&args);
    let Some(start) = target_start else {
        return Err("record requires a target command after --".into());
    };

    if start >= args.len() {
        return Err("record requires a non-empty target command".into());
    }

    let status = Command::new(&args[start])
        .args(&args[start + 1..])
        .status()?;
    process::exit(status.code().unwrap_or(1));
}

fn target_command_start(args: &[String]) -> Option<usize> {
    args.iter().position(|arg| arg == "--").map(|idx| idx + 1)
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
    use super::{parse_fixture_options, target_command_start, WriterFormat};

    #[test]
    fn finds_target_command_after_separator() {
        let args = ["--out-dir", "/tmp/trace", "--format", "json", "--", "erl"].map(String::from);

        assert_eq!(target_command_start(&args), Some(5));
    }

    #[test]
    fn rejects_record_args_without_target_separator() {
        let args = ["--out-dir", "/tmp/trace", "--format", "json"].map(String::from);

        assert_eq!(target_command_start(&args), None);
    }

    #[test]
    fn writer_fixture_defaults_to_ctfs() {
        let options = parse_fixture_options(vec!["--out-dir".into(), "/tmp/trace".into()]).unwrap();

        assert_eq!(options.format, WriterFormat::Ctfs);
    }
}
