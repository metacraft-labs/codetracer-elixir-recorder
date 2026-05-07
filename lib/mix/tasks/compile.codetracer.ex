defmodule Mix.Tasks.Compile.Codetracer do
  @moduledoc false

  use Mix.Task.Compiler

  @recursive false

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          build_dir: :string,
          include_app: :keep,
          exclude_app: :keep,
          include_module: :keep,
          exclude_module: :keep
        ]
      )

    if invalid != [] do
      Mix.raise("invalid codetracer compile options: #{inspect(invalid)}")
    end

    result =
      CodetracerBeamRecorder.ElixirSourceMap.build_mix_project(
        build_dir: opts[:build_dir],
        include_apps: Keyword.get_values(opts, :include_app),
        exclude_apps: Keyword.get_values(opts, :exclude_app),
        include_modules: Keyword.get_values(opts, :include_module),
        exclude_modules: Keyword.get_values(opts, :exclude_module)
      )

    Mix.shell().info(
      "codetracer: compiled #{length(result.summary.trace_functions)} traceable functions into #{result.build_dir}"
    )

    {:ok, []}
  end
end
