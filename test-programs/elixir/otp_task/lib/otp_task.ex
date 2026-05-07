defmodule OtpTask do
  @moduledoc """
  Task fixture for the M17 OTP fixture matrix. Exercises Task.async/1,
  Task.await/2, and Task.async_stream/3 over a small input list. The
  Task module is part of OTP and runs on top of `proc_lib`, so the
  recorder observes spawn/exit/send/receive events for each task.
  """

  def double(x), do: x * 2

  def main do
    task = Task.async(fn -> double(21) end)
    forty_two = Task.await(task, 5_000)
    true = forty_two == 42

    sum =
      1..4
      |> Task.async_stream(&double/1, max_concurrency: 2, ordered: true, timeout: 5_000)
      |> Enum.reduce(0, fn {:ok, value}, acc -> acc + value end)

    true = sum == 20
    IO.puts("task-ok: #{forty_two + sum}")
    :ok
  end
end
