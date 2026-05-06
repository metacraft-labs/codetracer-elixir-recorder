use std::env;
use std::process::{self, Command};

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    let mut args = env::args().skip(1).collect::<Vec<_>>();

    if env::var("CODETRACER_ELIXIR_RECORDER_DISABLED").as_deref() == Ok("1") {
        eprintln!(
            "codetracer-elixir-recorder is disabled by CODETRACER_ELIXIR_RECORDER_DISABLED=1"
        );
        process::exit(1);
    }

    if args.is_empty() {
        print_help();
        return;
    }

    match args.remove(0).as_str() {
        "-h" | "--help" => print_help(),
        "-V" | "--version" | "version" => println!("codetracer-elixir-recorder {VERSION}"),
        "record" => pass_through_target(args),
        "instrument" | "compile" => {
            eprintln!("recorder behavior is not implemented in M0");
            process::exit(1);
        }
        command => {
            eprintln!("unknown command: {command}");
            print_help();
            process::exit(1);
        }
    }
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

fn pass_through_target(args: Vec<String>) {
    let target_start = target_command_start(&args);
    let Some(start) = target_start else {
        eprintln!("record requires a target command after --");
        process::exit(1);
    };

    if start >= args.len() {
        eprintln!("record requires a non-empty target command");
        process::exit(1);
    }

    let status = Command::new(&args[start])
        .args(&args[start + 1..])
        .status()
        .unwrap_or_else(|error| {
            eprintln!("failed to launch target command: {error}");
            process::exit(1);
        });

    process::exit(status.code().unwrap_or(1));
}

fn target_command_start(args: &[String]) -> Option<usize> {
    args.iter().position(|arg| arg == "--").map(|idx| idx + 1)
}

#[cfg(test)]
mod tests {
    use super::target_command_start;

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
}
