defmodule CodetracerElixirRecorder.RuntimeBootstrap do
  @moduledoc false

  def start_session(options) do
    :codetracer_erlang_runtime.start_session(options)
  end

  def stop_session(reason) do
    :codetracer_erlang_runtime.stop_session(reason)
  end
end
