defmodule TaskMessages do
  @moduledoc false

  def main do
    parent = self()

    task =
      Task.async(fn ->
        receive do
          {:task_go, ^parent, 41} ->
            send(parent, {:task_ready, self(), 42})
        end

        receive do
          {:task_ack, ^parent} ->
            :task_done
        end
      end)

    send(task.pid, {:task_go, parent, 41})

    receive do
      {:task_ready, task_pid, 42} when task_pid == task.pid ->
        send(task.pid, {:task_ack, parent})
    end

    :task_done = Task.await(task)
    IO.puts("task-ok")
    :task_done
  end
end
