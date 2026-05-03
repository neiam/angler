defmodule AnglerWeb.Plugs.RawBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that caches the raw request body in
  `conn.assigns[:raw_body]`.

  We need this because HTTP signatures verify against the byte-exact body. By
  default Plug.Parsers consumes the body once and we can't re-read it. This
  reader appends each chunk to a list, which we reverse and concatenate when
  the controller reads it.

  Configured in `endpoint.ex`'s `Plug.Parsers` invocation. Adds a small
  per-request memory cost (one extra copy of the body); fine at 1 MiB cap.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = put_assign(conn, body)
        {:ok, body, conn}

      {:more, partial, conn} ->
        conn = put_assign(conn, partial)
        {:more, partial, conn}

      {:error, _} = err ->
        err
    end
  end

  defp put_assign(conn, body) do
    Plug.Conn.assign(conn, :raw_body, [body | conn.assigns[:raw_body] || []])
  end

  @doc "Return the full raw body for the current request, or `\"\"` if missing."
  @spec raw_body(Plug.Conn.t()) :: binary()
  def raw_body(conn) do
    conn.assigns
    |> Map.get(:raw_body, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
