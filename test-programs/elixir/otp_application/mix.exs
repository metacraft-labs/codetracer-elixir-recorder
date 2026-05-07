defmodule OtpApplication.MixProject do
  use Mix.Project

  def project do
    [
      app: :otp_application,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false
    ]
  end

  def application do
    [
      mod: {OtpApplication, []},
      extra_applications: [:logger]
    ]
  end
end
