ExUnit.start()

defmodule CodetracerBeamRecorder.CtfsWriterBridgeTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../..", __DIR__)

  test "e2e_ctfs_writer_bridge_roundtrip" do
    summary =
      run_bridge!(
        "ctfs",
        [
          "writer-fixture",
          "--out-dir",
          tmp_dir!("ctfs")
        ]
      )

    assert_field(summary, "status", "ok")
    assert_field(summary, "format", "ctfs")
    assert_field(summary, "writer", "codetracer_trace_writer_nim")
    assert_contains(summary, "reader", "NimTraceReaderHandle")
    assert_count_at_least(summary, "path_count", 1)
    assert_count_at_least(summary, "step_count", 2)
    assert_count_at_least(summary, "event_count", 1)
    assert_contains(summary, "first_path", "canonical_flow.ex")
    assert_contains(summary, "diagnostic_event", "ctfs writer bridge fixture")
  end

  test "e2e_json_diagnostic_writer_roundtrip" do
    summary =
      run_bridge!(
        "json",
        [
          "writer-fixture",
          "--format",
          "json",
          "--out-dir",
          tmp_dir!("json")
        ]
      )

    assert_field(summary, "status", "ok")
    assert_field(summary, "format", "json")
    assert_contains(summary, "writer", "NonStreamingTraceWriter")
    assert_contains(summary, "reader", "JsonTraceReader")
    assert_count_at_least(summary, "path_count", 1)
    assert_count_at_least(summary, "step_count", 2)
    assert_count_at_least(summary, "event_count", 1)
    assert_contains(summary, "first_path", "canonical_flow.ex")
    assert summary =~ "json writer bridge fixture"
  end

  defp run_bridge!(label, bridge_args) do
    args = ["run", "--locked", "--quiet", "--"] ++ bridge_args
    {output, status} = System.cmd("cargo", args, cd: @repo_root, stderr_to_stdout: true)

    assert status == 0, """
    bridge command failed for #{label} with status #{status}

    #{output}
    """

    output
  end

  defp tmp_dir!(label) do
    path = Path.join(System.tmp_dir!(), "codetracer-beam-recorder-m2-#{label}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp assert_field(json, field, expected) do
    assert json =~ ~s("#{field}":"#{expected}"), "expected #{field}=#{expected}, got: #{json}"
  end

  defp assert_contains(json, field, expected) do
    pattern = ~r/"#{Regex.escape(field)}":"[^"]*#{Regex.escape(expected)}[^"]*"/
    assert json =~ pattern, "expected #{field} to contain #{expected}, got: #{json}"
  end

  defp assert_count_at_least(json, field, minimum) do
    pattern = ~r/"#{Regex.escape(field)}":([0-9]+)/
    assert [_, value] = Regex.run(pattern, json), "expected numeric #{field}, got: #{json}"
    assert String.to_integer(value) >= minimum, "expected #{field} >= #{minimum}, got: #{json}"
  end
end
