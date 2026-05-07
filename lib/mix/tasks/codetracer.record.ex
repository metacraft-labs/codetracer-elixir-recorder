defmodule Mix.Tasks.Codetracer.Record do
  @moduledoc false

  use Mix.Task

  @shortdoc "Record a Mix project with CodeTracer"

  @impl true
  def run(args) do
    {recorder_args, target_args} = split_target_args(args)

    {opts, rest, invalid} =
      OptionParser.parse(recorder_args,
        strict: [
          out_dir: :string,
          build_dir: :string,
          eval: :string,
          include_app: :keep,
          exclude_app: :keep,
          include_module: :keep,
          exclude_module: :keep,
          capture_messages: :string,
          value_max_depth: :integer,
          value_max_sequence_items: :integer,
          value_max_binary_bytes: :integer,
          value_max_map_pairs: :integer,
          value_max_string_bytes: :integer
        ],
        aliases: [o: :out_dir, e: :eval]
      )

    if invalid != [] or rest != [] do
      Mix.raise("invalid codetracer.record options: #{inspect(invalid ++ rest)}")
    end

    build_dir = Path.expand(opts[:build_dir] || CodetracerBeamRecorder.ElixirSourceMap.default_build_dir())
    out_dir = Path.expand(opts[:out_dir] || "ct-traces")

    compile_args =
      ["--build-dir", build_dir] ++
        repeated("--include-app", Keyword.get_values(opts, :include_app)) ++
        repeated("--exclude-app", Keyword.get_values(opts, :exclude_app)) ++
        repeated("--include-module", Keyword.get_values(opts, :include_module)) ++
        repeated("--exclude-module", Keyword.get_values(opts, :exclude_module))

    Mix.Task.reenable("compile.codetracer")
    Mix.Task.run("compile.codetracer", compile_args)

    recorder = recorder_binary!()

    target =
      cond do
        target_args != [] ->
          target_args

        opts[:eval] ->
          ["mix", "run", "--no-compile", "-e", opts[:eval]]

        true ->
          Mix.raise("codetracer.record requires --eval EXPR or a target after --")
      end

    command =
      ["record", "--out-dir", out_dir, "--build-dir", build_dir] ++
        option_pair("--capture-messages", opts[:capture_messages]) ++
        integer_pair("--value-max-depth", opts[:value_max_depth]) ++
        integer_pair("--value-max-sequence-items", opts[:value_max_sequence_items]) ++
        integer_pair("--value-max-binary-bytes", opts[:value_max_binary_bytes]) ++
        integer_pair("--value-max-map-pairs", opts[:value_max_map_pairs]) ++
        integer_pair("--value-max-string-bytes", opts[:value_max_string_bytes]) ++
        ["--"] ++ target

    {output, status} = System.cmd(recorder, command, stderr_to_stdout: true)
    IO.write(output)

    if status != 0 do
      Mix.raise("codetracer recorder exited with status #{status}")
    end

    :ok
  end

  defp split_target_args(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {left, []} -> {left, []}
      {left, [_separator | right]} -> {left, right}
    end
  end

  defp recorder_binary! do
    System.get_env("CODETRACER_BEAM_RECORDER_BIN") ||
      System.get_env("CODETRACER_ELIXIR_RECORDER_BIN") ||
      System.find_executable("codetracer-beam-recorder") ||
      System.find_executable("codetracer-elixir-recorder") ||
      Mix.raise("codetracer-beam-recorder was not found on PATH")
  end

  defp repeated(_flag, []), do: []
  defp repeated(flag, values), do: Enum.flat_map(values, &[flag, &1])

  defp option_pair(_flag, nil), do: []
  defp option_pair(flag, value), do: [flag, value]

  defp integer_pair(_flag, nil), do: []
  defp integer_pair(flag, value), do: [flag, Integer.to_string(value)]
end
