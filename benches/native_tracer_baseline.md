# M16 Native Tracer Benchmark Baseline

Captured: 2026-05-07T20:54:38.257851Z

Recorder: codetracer-beam-recorder, --tracer-backend {process|native}.
Workloads exercise the three M16 pressure axes against real BEAM
targets via `erl -s native_tracer_bench <entry>`.

| fixture | backend | wall_us | event_count | sidecar_bytes |
| --- | --- | ---: | ---: | ---: |
| call_heavy | process | 1300640 | 14 | 7977 |
| call_heavy | native | 1320370 | 14 | 7446 |
| process_heavy | process | 1531022 | 1946 | 715271 |
| process_heavy | native | 1402605 | 1916 | 764348 |
| message_heavy | process | 1385893 | 2028 | 630161 |
| message_heavy | native | 1510845 | 2028 | 699023 |

Notes:
- Wall-clock time is for the *whole record + target run*, including
  BEAM boot, instrumentation, target execution, and shutdown barrier.
  Subtract the BEAM-boot baseline (~200ms cold) when comparing
  backends.
- The native backend currently writes events to the same JSONL
  sidecar as the process backend; relative performance reflects the
  cost of the dedicated tracer process + atomic sequence counter
  versus the gen_server tracer. A real `erl_tracer` NIF (M17) is
  expected to widen the gap.
- Event_count counts trace events (excluding the trace_delivered
  summary line and any manifest_loaded headers).
- Run `just test-integration` (or `elixir tests/integration/native_tracer_bench_test.exs`)
  to refresh this baseline.
