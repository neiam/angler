defmodule AnglerWeb.MastodonAPI.MutedTagController do
  @moduledoc """
  Muted hashtags (an Angler extension — Mastodon has no native muted-tag API).

    * GET    /api/v1.1/muted-tags        — list `{name, filter_action}`
    * POST   /api/v1.1/muted-tags        — mute `{tag, filter_action}`
    * DELETE /api/v1.1/muted-tags/:name  — unmute

  The action (`blur` / `warn` / `hide`) is applied at render time by
  `Angler.Filters.Matching`, the same path keyword filters flow through.
  """

  use AnglerWeb, :controller

  alias Angler.Hashtags.Muting
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, Enum.map(Muting.list(profile.id), &render_mute/1))
  end

  def create(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    name = params["tag"] || params["name"] || ""
    action = params["filter_action"] || params["action"] || "hide"

    case Muting.mute(profile, to_string(name), to_string(action)) do
      {:ok, tag} -> json(conn, render_mute({tag, action}))
      {:error, _} -> conn |> put_status(422) |> json(%{"error" => "could not mute tag"})
    end
  end

  def delete(conn, %{"name" => name}) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    :ok = Muting.unmute(profile, name)
    json(conn, %{})
  end

  defp render_mute({tag, action}) do
    %{"name" => tag.name, "filter_action" => action}
  end
end
