defmodule PlugSmoke.Server do
  @moduledoc """
  Minimal hand-rolled HTTP/1.1 server using `:gen_tcp`. The server
  binds to an OS-assigned port, accepts a single connection, parses
  the request line and headers, dispatches through `PlugSmoke.Router`,
  and writes back a fixed-length response.
  """

  def serve_one(port_writer \\ nil) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        packet: :http_bin
      ])

    {:ok, port} = :inet.port(listen)
    if is_function(port_writer, 1), do: port_writer.(port)

    {:ok, socket} = :gen_tcp.accept(listen, 5_000)
    request = read_request(socket, %{headers: []})
    response = PlugSmoke.Router.route(request)

    head =
      "HTTP/1.1 #{response.status} OK\r\n" <>
        "Content-Type: text/plain\r\n" <>
        "Content-Length: #{response.content_length}\r\n" <>
        "Connection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, head <> response.body)
    :ok = :gen_tcp.close(socket)
    :ok = :gen_tcp.close(listen)
    response
  end

  defp read_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} ->
        :inet.setopts(socket, packet: :httph_bin)
        read_request(socket, Map.merge(acc, %{method: to_string(method), path: path}))

      {:ok, {:http_header, _, name, _, value}} ->
        read_request(socket, %{acc | headers: [{to_string(name), value} | acc.headers]})

      {:ok, :http_eoh} ->
        acc

      {:ok, {:http_error, _line}} ->
        acc

      {:error, _} ->
        acc
    end
  end
end
