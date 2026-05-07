defmodule CodetracerBeamRecorder.MixProject do
  use Mix.Project

  def project do
    [
      app: :codetracer_beam_recorder,
      version: "0.1.0",
      elixir: "~> 1.15",
      build_embedded: false,
      start_permanent: false
    ]
  end
end
