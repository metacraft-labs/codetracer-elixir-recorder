# M16 Native Tracer Benchmark Baseline

Captured: 2026-05-12T07:00:11.464170Z

Recorder: codetracer-beam-recorder, --tracer-backend {process|native}.
Workloads exercise the three M16 pressure axes against real BEAM
targets via `erl -s native_tracer_bench <entry>`.

| fixture | backend | wall_us | event_count | sidecar_bytes |
| --- | --- | ---: | ---: | ---: |
| call_heavy | process | 1492497 | 14 | 7884 |
| call_heavy | native | 1448238 | 14 | 7417 |
| process_heavy | process | 1465619 | 1942 | 713040 |
| process_heavy | native | 1569187 | 1954 | 785773 |
| message_heavy | process | 1438380 | 2032 | 632173 |
| message_heavy | native | 1516944 | 2030 | 700121 |

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
