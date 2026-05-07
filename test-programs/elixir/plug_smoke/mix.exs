defmodule PlugSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :plug_smoke,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
