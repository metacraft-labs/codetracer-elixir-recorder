defmodule OtpAgent do
  @moduledoc """
  Agent fixture for the M17 OTP fixture matrix. Agent is a GenServer
  shaped for state holding; this fixture exercises Agent.start_link/1,
  Agent.update/2, Agent.get/2, and Agent.stop/1. The recorder sees the
  underlying call/reply traffic between the calling process and the
  Agent.
  """

  def main do
    {:ok, pid} = Agent.start_link(fn -> %{count: 0, history: []} end)
    Agent.update(pid, fn s -> %{s | count: s.count + 1, history: [:a | s.history]} end)
    Agent.update(pid, fn s -> %{s | count: s.count + 41, history: [:b | s.history]} end)
    state = Agent.get(pid, & &1)
    true = state.count == 42
    true = Enum.reverse(state.history) == [:a, :b]
    IO.puts("agent-ok: #{state.count}")
    Agent.stop(pid, :normal)
    :ok
  end
end
