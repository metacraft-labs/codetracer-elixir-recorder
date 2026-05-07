defmodule OtpSupervisor.Worker do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts), do: {:ok, Keyword.get(opts, :state, 0)}

  @impl true
  def handle_call(:value, _from, state), do: {:reply, state, state}
end

defmodule OtpSupervisor.Tree do
  @moduledoc """
  Real OTP Supervisor wired with two child GenServers under one_for_one
  strategy. The fixture demonstrates real supervisor lifecycle through
  Supervisor.start_link/2, Supervisor.which_children/1, and graceful
  shutdown via Supervisor.stop/1 — all of which surface as observable
  trace events.
  """

  use Supervisor

  def start_link(_opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      Supervisor.child_spec(
        {OtpSupervisor.Worker, [name: :otp_supervisor_a, state: 1]},
        id: :a
      ),
      Supervisor.child_spec(
        {OtpSupervisor.Worker, [name: :otp_supervisor_b, state: 2]},
        id: :b
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule OtpSupervisor do
  @moduledoc false

  def main do
    {:ok, sup} = OtpSupervisor.Tree.start_link()
    children = Supervisor.which_children(OtpSupervisor.Tree)
    true = length(children) == 2
    a = GenServer.call(:otp_supervisor_a, :value)
    b = GenServer.call(:otp_supervisor_b, :value)
    true = a + b == 3
    IO.puts("supervisor-ok: #{a + b}")
    Supervisor.stop(sup, :normal)
    :ok
  end
end
