set shell := ["bash", "-euo", "pipefail", "-c"]

build:
  if ! command -v cargo >/dev/null 2>&1; then nix develop --command just build; else just build-native; fi

build-native:
  cargo build --locked
  cd rebar3_codetracer && rebar3 compile

test:
  if ! command -v cargo >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v elixir >/dev/null 2>&1 || ! command -v mix >/dev/null 2>&1 || ! command -v erl >/dev/null 2>&1 || ! command -v erlc >/dev/null 2>&1 || ! command -v rebar3 >/dev/null 2>&1; then nix develop --command just test; else just test-rust && just test-goldens && just test-elixir && just test-erlang && just verify-trace-format-dependency && just test-integration && just verify-elixir-fixture-generation-no-silent-skip && just verify-beam-fixture-generation-no-silent-skip && just verify-runtime-session-test-no-silent-skip && just verify-function-trace-test-no-silent-skip && just verify-message-trace-test-no-silent-skip && just verify-manifest-source-location-test-no-silent-skip && just verify-step-instrumentation-test-no-silent-skip && just verify-native-tracer-parity-test-no-silent-skip && just verify-native-tracer-ordering-test-no-silent-skip && just verify-native-tracer-overflow-test-no-silent-skip && just verify-native-tracer-bench-test-no-silent-skip; fi

t: test

test-rust:
  cargo test --locked

test-elixir:
  bash tests/fixtures/run-elixir-canonical-flow.sh

test-erlang:
  bash tests/fixtures/run-erlang-canonical-flow.sh

test-goldens:
  bash tests/verify-golden-contract.sh

test-integration:
  cargo run --locked -- --help >/dev/null
  cargo run --locked -- --version | grep -F "$(grep -E '^version = "' Cargo.toml | head -n1 | cut -d '"' -f2)"
  trace_dir="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-beam-recorder-cli.XXXXXX")"; set +e; cargo run --locked -- record --out-dir "$trace_dir" -- sh -c 'exit 7'; status="$?"; set -e; rm -rf "$trace_dir"; test "$status" -eq 7
  elixir tests/integration/ctfs_writer_bridge_test.exs
  cargo build --locked
  elixir tests/integration/runtime_session_test.exs
  elixir tests/integration/function_trace_test.exs
  elixir tests/integration/message_trace_test.exs
  elixir tests/integration/manifest_source_location_test.exs
  elixir tests/integration/step_instrumentation_test.exs
  elixir tests/integration/native_tracer_parity_test.exs
  elixir tests/integration/native_tracer_ordering_test.exs
  elixir tests/integration/native_tracer_overflow_test.exs
  elixir tests/integration/native_tracer_bench_test.exs

verify-trace-format-dependency:
  bash tests/verify-trace-format-dependency.sh

verify-elixir-fixture-generation-no-silent-skip:
  bash tests/verify-elixir-fixture-generation-no-silent-skip.sh

verify-beam-fixture-generation-no-silent-skip:
  bash tests/verify-beam-fixture-generation-no-silent-skip.sh

verify-runtime-session-test-no-silent-skip:
  bash tests/verify-runtime-session-test-no-silent-skip.sh

verify-function-trace-test-no-silent-skip:
  bash tests/verify-function-trace-test-no-silent-skip.sh

verify-message-trace-test-no-silent-skip:
  bash tests/verify-message-trace-test-no-silent-skip.sh

verify-manifest-source-location-test-no-silent-skip:
  bash tests/verify-manifest-source-location-test-no-silent-skip.sh

verify-step-instrumentation-test-no-silent-skip:
  bash tests/verify-step-instrumentation-test-no-silent-skip.sh

verify-native-tracer-parity-test-no-silent-skip:
  bash tests/verify-native-tracer-parity-test-no-silent-skip.sh

verify-native-tracer-ordering-test-no-silent-skip:
  bash tests/verify-native-tracer-ordering-test-no-silent-skip.sh

verify-native-tracer-overflow-test-no-silent-skip:
  bash tests/verify-native-tracer-overflow-test-no-silent-skip.sh

verify-native-tracer-bench-test-no-silent-skip:
  bash tests/verify-native-tracer-bench-test-no-silent-skip.sh

lint:
  if ! command -v cargo >/dev/null 2>&1 || ! command -v nixfmt >/dev/null 2>&1 || ! command -v shellcheck >/dev/null 2>&1; then nix develop --command just lint; else just lint-nix && just lint-rust && just lint-shell && just verify-repo-requirements && just verify-trace-format-dependency; fi

lint-nix:
  nixfmt --check flake.nix

lint-rust:
  cargo fmt --check
  cargo clippy --locked --all-targets -- -D warnings

lint-shell:
  shellcheck tests/verify-repo-requirements.sh tests/verify-golden-contract.sh tests/verify-trace-format-dependency.sh tests/verify-elixir-fixture-generation-no-silent-skip.sh tests/verify-beam-fixture-generation-no-silent-skip.sh tests/verify-runtime-session-test-no-silent-skip.sh tests/verify-function-trace-test-no-silent-skip.sh tests/verify-message-trace-test-no-silent-skip.sh tests/verify-manifest-source-location-test-no-silent-skip.sh tests/verify-step-instrumentation-test-no-silent-skip.sh tests/verify-native-tracer-parity-test-no-silent-skip.sh tests/verify-native-tracer-ordering-test-no-silent-skip.sh tests/verify-native-tracer-overflow-test-no-silent-skip.sh tests/verify-native-tracer-bench-test-no-silent-skip.sh tests/fixtures/*.sh scripts/*.sh

verify-repo-requirements:
  bash tests/verify-repo-requirements.sh

format:
  if ! command -v cargo >/dev/null 2>&1 || ! command -v nixfmt >/dev/null 2>&1 || ! command -v shfmt >/dev/null 2>&1; then nix develop --command just format; else just format-nix && just format-rust && just format-shell; fi

fmt: format

format-nix:
  nixfmt flake.nix

format-rust:
  cargo fmt

format-shell:
  shfmt -w tests/verify-repo-requirements.sh tests/verify-golden-contract.sh tests/verify-trace-format-dependency.sh tests/verify-elixir-fixture-generation-no-silent-skip.sh tests/verify-beam-fixture-generation-no-silent-skip.sh tests/verify-runtime-session-test-no-silent-skip.sh tests/verify-function-trace-test-no-silent-skip.sh tests/verify-message-trace-test-no-silent-skip.sh tests/verify-manifest-source-location-test-no-silent-skip.sh tests/verify-step-instrumentation-test-no-silent-skip.sh tests/verify-native-tracer-parity-test-no-silent-skip.sh tests/verify-native-tracer-ordering-test-no-silent-skip.sh tests/verify-native-tracer-overflow-test-no-silent-skip.sh tests/verify-native-tracer-bench-test-no-silent-skip.sh tests/fixtures/*.sh scripts/*.sh

test-integration-fixture:
  just test-integration

bench:
  cargo build --release --locked
  target/release/codetracer-beam-recorder --version >/dev/null

bump-version new_version:
  case "{{new_version}}" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "version must be semver MAJOR.MINOR.PATCH" >&2; exit 1 ;; esac
  sed -i.bak -E 's/^version = "[^"]+"/version = "{{new_version}}"/' Cargo.toml
  rm -f Cargo.toml.bak
  cargo update --workspace
