defmodule OtpGenServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :otp_genserver,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
