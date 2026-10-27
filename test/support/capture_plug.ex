defmodule Angler.Test.CapturePlug do
  @moduledoc """
  A plug for a throwaway local HTTP server in tests: sends each request
  it receives (method, path, headers, body) to the `:test` pid it was
  given, then answers with `:status` (default 201).

  For checking what really goes over the wire, which a `Req.Test` stub
  doesn't always show (its adapter strips `content-encoding`).
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, %{test: test} = opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test, {:captured, conn.method, conn.request_path, conn.req_headers, body})
    Plug.Conn.send_resp(conn, Map.get(opts, :status, 201), "")
  end
end
