defmodule OtpApplication.Worker do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, :ready}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule OtpApplication do
  @moduledoc """
  Real OTP Application fixture: implements the Application behaviour
  with start/2 + stop/1, registers a supervised worker, and exposes a
  `:main/0` driver that boots the application, exercises the worker,
  and shuts it down. The recorder observes Application.start, the
  supervisor tree starting the worker, the GenServer call/reply, and
  Application.stop.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [OtpApplication.Worker]
    Supervisor.start_link(children, strategy: :one_for_one, name: OtpApplication.Sup)
  end

  @impl true
  def stop(_state), do: :ok

  def main do
    {:ok, _started} = Application.ensure_all_started(:otp_application)
    :pong = GenServer.call(OtpApplication.Worker, :ping)
    IO.puts("application-ok: pong")
    :ok = Application.stop(:otp_application)
    :ok
  end
end
