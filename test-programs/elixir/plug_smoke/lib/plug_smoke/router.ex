defmodule PlugSmoke.Router do
  @moduledoc """
  Tiny request handler shaped like a Plug.Router. Accepts a parsed
  request map (method, path, headers, body) and returns a response
  map. The handler is intentionally Plug-shaped so the recorded call
  sequence (`route/1` -> `dispatch/2` -> `render/2`) maps onto the
  request handler call sequence the M17 verification tracks.

  Note: this fixture does not depend on the `:plug` Hex package
  because the recorder dev shell is offline. The shape mirrors
  Plug.Router so a future swap to Plug + Cowboy is mechanical.
  """

  def route(request) do
    method = request.method
    path = request.path
    dispatch(method, path)
  end

  def dispatch(method, path) do
    case {method, path} do
      {"GET", "/healthz"} ->
        render(200, "ok\n")

      {"GET", "/echo"} ->
        render(200, "echo\n")

      {"GET", _other} ->
        render(404, "not_found\n")

      _ ->
        render(405, "method_not_allowed\n")
    end
  end

  def render(status, body) when is_integer(status) and is_binary(body) do
    %{status: status, body: body, content_length: byte_size(body)}
  end
end
