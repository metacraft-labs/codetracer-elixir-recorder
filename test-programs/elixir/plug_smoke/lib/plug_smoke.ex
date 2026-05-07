defmodule PlugSmoke do
  @moduledoc """
  Driver: handle a single request synchronously in the calling process
  (no spawn) so the recorder traces the full request handler call
  sequence (Router.route -> dispatch -> render) under the recorded
  root pid. Then exercise the gen_tcp end-to-end path as well so the
  fixture also produces real wire traffic for the recorder to observe.
  """

  def main do
    # 1) Synchronous in-process request to guarantee the
    #    Router.route/1 -> dispatch/2 -> render/2 sequence appears in
    #    the recorder's traced parent thread.
    request = %{method: "GET", path: "/healthz", headers: [], body: ""}
    response = PlugSmoke.Router.route(request)
    true = response.status == 200

    # 2) End-to-end gen_tcp request to exercise spawn + send/receive
    #    and prove the request fixture is request-oriented over a real
    #    socket — not just an in-process function call.
    parent = self()

    server =
      spawn_link(fn ->
        send(parent, {:served, PlugSmoke.Server.serve_one(fn p -> send(parent, {:bound, p}) end)})
      end)

    port =
      receive do
        {:bound, p} -> p
      after
        5_000 -> raise "server failed to bind"
      end

    wire = PlugSmoke.Client.get(port, "/healthz")
    true = String.contains?(wire, "200")
    true = String.contains?(wire, "ok")

    receive do
      {:served, _} -> :ok
    after
      5_000 -> raise "server failed to respond"
    end

    Process.unlink(server)
    IO.puts("plug-smoke-ok")
    :ok
  end
end
