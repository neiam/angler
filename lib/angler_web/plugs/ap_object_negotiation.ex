defmodule AnglerWeb.Plugs.APObjectNegotiation do
  @moduledoc """
  Content-negotiates the canonical status permalink `/p/:username/:id`.

  Browsers (and anything not asking for ActivityPub) fall through to the
  `StatusLive` LiveView. Federation peers that send an
  `application/activity+json` / `application/ld+json` `Accept` header get the
  AP `Note` object instead — Pixelfed and friends re-fetch the object `id` to
  verify a pushed `Create`, and would otherwise receive HTML and drop the post.

  Runs *before* the browser pipeline's `plug :accepts, ["html"]`, which would
  reject AP `Accept` headers with 406.
  """

  import Plug.Conn

  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.Status
  alias Angler.Federation.NoteBuilder

  @ap_types ["application/activity+json", "application/ld+json"]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["p", username, id]} = conn, _opts) do
    if ap_requested?(conn), do: serve_object(conn, username, id), else: conn
  end

  def call(conn, _opts), do: conn

  defp ap_requested?(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",")
    Enum.any?(@ap_types, &String.contains?(accept, &1))
  end

  defp serve_object(conn, username, id) do
    with {int_id, ""} <- Integer.parse(id),
         %Status{local: true} = status <- Statuses.get(int_id),
         status = Repo.preload(status, :profile),
         true <- status.profile && status.profile.username == username,
         true <- Statuses.visible_to?(status, nil) do
      body = Jason.encode!(NoteBuilder.object(status))

      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, body)
      |> halt()
    else
      _ ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(404, Jason.encode!(%{"error" => "Not found"}))
        |> halt()
    end
  end
end
