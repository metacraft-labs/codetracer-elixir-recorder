defmodule OtpGenServer.Counter do
  @moduledoc """
  Minimal GenServer fixture for the M17 OTP fixture matrix. The behaviour
  exercises GenServer.start_link/3, handle_call/3, handle_cast/2, and the
  terminate/2 shutdown path so the recorder produces call, return, send,
  and receive trace events under a real OTP behaviour.
  """

  use GenServer

  def start_link(initial \\ 0) do
    GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  end

  @impl true
  def init(initial) do
    {:ok, initial}
  end

  @impl true
  def handle_call(:value, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:add, n}, state), do: {:noreply, state + n}

  @impl true
  def terminate(_reason, _state), do: :ok
end

defmodule OtpGenServer do
  @moduledoc false

  def main do
    {:ok, pid} = OtpGenServer.Counter.start_link(0)
    GenServer.cast(OtpGenServer.Counter, {:add, 4})
    GenServer.cast(OtpGenServer.Counter, {:add, 38})
    value = GenServer.call(OtpGenServer.Counter, :value)
    true = value == 42
    IO.puts("genserver-ok: #{value}")
    GenServer.stop(pid, :normal)
    :ok
  end
end
