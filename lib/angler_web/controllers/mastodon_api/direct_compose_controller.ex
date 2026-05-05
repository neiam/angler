defmodule AnglerWeb.MastodonAPI.DirectComposeController do
  @moduledoc """
  Pixelfed `direct/*` compose helpers (the *picker* surface — DM thread
  endpoints live in `DirectThreadController`).

    * POST /api/v1.1/direct/lookup       — resolve a `username` (or acct) to
      a small profile-summary JSON the composer needs to seed a thread.
    * GET  /api/v1.1/direct/compose/mutuals — list of profiles the viewer
      and the targets mutually follow (used for "compose to mutuals" UI).
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  def lookup(conn, %{"username" => username}) when is_binary(username) do
    case Profiles.lookup_acct(username) do
      %Profile{} = p -> json(conn, summary(p))
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def lookup(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{"error" => "username required"})

  def mutuals(conn, _params) do
    %{profile: viewer} = BearerAuth.current_scope(conn)

    # "Mutuals" = profiles the viewer follows AND who follow the viewer.
    following =
      Repo.all(
        from f in Follower,
          where: f.following_id == ^viewer.id and not is_nil(f.accepted_at),
          select: f.profile_id
      )
      |> MapSet.new()

    if MapSet.size(following) == 0 do
      json(conn, [])
    else
      followers_back =
        Repo.all(
          from f in Follower,
            where:
              f.profile_id == ^viewer.id and f.following_id in ^MapSet.to_list(following) and
                not is_nil(f.accepted_at),
            select: f.following_id
        )

      profiles =
        Repo.all(
          from p in Profile,
            where: p.id in ^followers_back and is_nil(p.status),
            order_by: [asc: p.username],
            limit: 50
        )

      json(conn, Enum.map(profiles, &Account.render/1))
    end
  end

  defp summary(%Profile{} = p) do
    %{
      "id" => Integer.to_string(p.id),
      "username" => p.username,
      "acct" => acct(p),
      "display_name" => p.name || "",
      "avatar" => p.avatar_path || "",
      "url" => Profiles.url(p),
      "locked" => p.is_private,
      "is_local" => is_nil(p.domain),
      "domain" => p.domain
    }
  end

  defp acct(%Profile{domain: nil, username: u}), do: u
  defp acct(%Profile{domain: d, username: u}), do: "#{u}@#{d}"
end
