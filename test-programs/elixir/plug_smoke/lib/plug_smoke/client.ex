defmodule PlugSmoke.Client do
  @moduledoc false

  def get(port, path) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        active: false,
        packet: :raw
      ])

    request =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1\r\n" <>
        "Connection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    response = drain(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp drain(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> drain(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end
end
