defmodule AnglerWeb.MastodonAPI.AccountController do
  @moduledoc """
  Mastodon-compatible account endpoints.

  This slice covers `verify_credentials`, follow/unfollow, and the
  relationships batch lookup. Account fetch by id and the broader
  accounts-grouping surface lands later.
  """

  use AnglerWeb, :controller

  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Relationships
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Relationship, as: RelationshipJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /accounts/verify_credentials

  def verify_credentials(conn, _params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)
    base = Account.render(profile)
    json(conn, Map.put(base, "source", source_block(user, profile)))
  end

  ## POST /accounts/:id/follow

  def follow(conn, %{"id" => id}) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, target_id} <- parse_id(id),
         %Profile{} = target <- Profiles.get_profile(target_id),
         {:ok, _state, _row} <- Follows.follow(actor, target) do
      respond_relationship(conn, actor.id, target_id)
    else
      {:error, :self_follow} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "Cannot follow yourself"})

      {:error, reason} when is_atom(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => Atom.to_string(reason)})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## POST /accounts/:id/unfollow

  def unfollow(conn, %{"id" => id}) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, target_id} <- parse_id(id),
         %Profile{} = target <- Profiles.get_profile(target_id),
         :ok <- Follows.unfollow(actor, target) do
      respond_relationship(conn, actor.id, target_id)
    else
      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /accounts/relationships?id[]=…

  def relationships(conn, params) do
    %{profile: viewer} = BearerAuth.current_scope(conn)

    raw_ids =
      case params["id"] do
        nil -> []
        list when is_list(list) -> list
        v when is_binary(v) -> [v]
      end

    target_ids =
      raw_ids
      |> Enum.map(&parse_id/1)
      |> Enum.flat_map(fn
        {:ok, n} -> [n]
        _ -> []
      end)

    rels = Relationships.batch(viewer.id, target_ids)
    body = Enum.map(target_ids, fn id -> Map.fetch!(rels, id) |> RelationshipJSON.render() end)
    json(conn, body)
  end

  ## Helpers

  defp respond_relationship(conn, viewer_id, target_id) do
    rel = Relationships.get(viewer_id, target_id)
    json(conn, RelationshipJSON.render(rel))
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp source_block(user, profile) do
    %{
      "privacy" => if(profile.is_private, do: "private", else: "public"),
      "sensitive" => false,
      "language" => user.language || "en",
      "note" => profile.bio || "",
      "fields" => []
    }
  end
end
