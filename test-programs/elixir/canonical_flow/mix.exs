defmodule CanonicalFlow.MixProject do
  use Mix.Project

  def project do
    [
      app: :canonical_flow,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end
end
