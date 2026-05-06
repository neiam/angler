defmodule AnglerWeb.MastodonAPI.AccountController do
  @moduledoc """
  Mastodon-compatible account endpoints.

  This slice covers `verify_credentials`, follow/unfollow, and the
  relationships batch lookup. Account fetch by id and the broader
  accounts-grouping surface lands later.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Follows
  alias Angler.Pagination.MastodonCursor
  alias Angler.Profiles
  alias Angler.Profiles.BlocksMutes
  alias Angler.Profiles.Profile
  alias Angler.Relationships
  alias Angler.Repo
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Relationship, as: RelationshipJSON
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /accounts/verify_credentials

  def verify_credentials(conn, params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)
    opts = render_opts(params, user)
    base = Account.render(profile, opts)
    json(conn, Map.put(base, "source", source_block(user, profile)))
  end

  ## PATCH /accounts/update_credentials

  def update_credentials(conn, params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)
    opts = render_opts(params, user)

    case Profiles.update_credentials(profile, params) do
      {:ok, updated} ->
        body = Account.render(updated, opts) |> Map.put("source", source_block(user, updated))
        json(conn, body)

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "Validation failed", "errors" => translate_errors(cs)})

      {:error, :not_local_profile} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Not a local profile"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => to_string(reason)})
    end
  end

  ## GET /accounts/:id

  def show(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Profiles.get_profile(int_id) do
      json(conn, Account.render(profile))
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /accounts/lookup?acct=foo@bar

  def lookup(conn, %{"acct" => acct}) do
    case Profiles.lookup_acct(acct) do
      nil -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
      profile -> json(conn, Account.render(profile))
    end
  end

  def lookup(conn, _), do: conn |> put_status(:bad_request) |> json(%{"error" => "acct required"})

  ## GET /accounts/search?q=...

  def search(conn, %{"q" => q} = params) do
    limit =
      case params["limit"] do
        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, ""} -> n |> max(1) |> min(40)
            _ -> 20
          end

        _ ->
          20
      end

    profiles = Profiles.search(q, limit: limit)
    json(conn, Enum.map(profiles, &Account.render/1))
  end

  def search(conn, _), do: conn |> put_status(:bad_request) |> json(%{"error" => "q required"})

  ## POST /accounts/:id/{block,unblock,mute,unmute}

  def block(conn, %{"id" => id}), do: do_relation_action(conn, id, :block)
  def unblock(conn, %{"id" => id}), do: do_relation_action(conn, id, :unblock)
  def mute(conn, %{"id" => id}), do: do_relation_action(conn, id, :mute)
  def unmute(conn, %{"id" => id}), do: do_relation_action(conn, id, :unmute)

  defp do_relation_action(conn, id, action) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, target_id} <- parse_id(id),
         %Profile{} = target <- Profiles.get_profile(target_id) do
      case action do
        :block -> BlocksMutes.block(actor, target)
        :unblock -> BlocksMutes.unblock(actor, target)
        :mute -> BlocksMutes.mute(actor, target)
        :unmute -> BlocksMutes.unmute(actor, target)
      end

      respond_relationship(conn, actor.id, target_id)
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /follow_requests

  def follow_requests(conn, params) do
    %{profile: actor} = BearerAuth.current_scope(conn)
    limit = parse_limit(params["limit"])

    rows = Follows.list_requests(actor.id, limit)
    body = Enum.map(rows, fn %{follower: p} -> Account.render(p) end)
    json(conn, body)
  end

  ## POST /follow_requests/:account_id/{authorize,reject}

  def authorize_request(conn, %{"id" => id}) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, follower_id} <- parse_id(id),
         %Profile{} = follower <- Profiles.get_profile(follower_id),
         {:ok, _} <- Follows.authorize_request(actor, follower) do
      respond_relationship(conn, actor.id, follower_id)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def reject_request(conn, %{"id" => id}) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, follower_id} <- parse_id(id),
         %Profile{} = follower <- Profiles.get_profile(follower_id) do
      :ok = Follows.reject_request(actor, follower)
      respond_relationship(conn, actor.id, follower_id)
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /blocks  /  GET /mutes

  def blocks(conn, _params) do
    %{profile: actor} = BearerAuth.current_scope(conn)
    json(conn, BlocksMutes.list_blocks(actor.id) |> Enum.map(&Account.render/1))
  end

  def mutes(conn, _params) do
    %{profile: actor} = BearerAuth.current_scope(conn)
    json(conn, BlocksMutes.list_mutes(actor.id) |> Enum.map(&Account.render/1))
  end

  ## GET /accounts/:id/pinned

  def pinned(conn, %{"id" => id}) do
    viewer_id = viewer_id(conn)

    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Profiles.get_profile(int_id) do
      statuses = Angler.Statuses.Pinning.list(profile.id)
      json(conn, StatusJSON.render_many(statuses, viewer_id))
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /accounts/:id/statuses

  def statuses(conn, %{"id" => id} = params) do
    viewer_id = viewer_id(conn)
    cursor = MastodonCursor.parse(params, 20, 40)

    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Profiles.get_profile(int_id) do
      base = author_visible_query(profile.id, viewer_id)
      base = filter_account_options(base, params)

      rows =
        base
        |> MastodonCursor.apply(cursor, :id)
        |> Repo.all()
        |> MastodonCursor.finalize_order(cursor, :id)

      conn =
        case MastodonCursor.link_header(rows, current_url_without_cursor(conn), :id) do
          nil -> conn
          v -> put_resp_header(conn, "link", v)
        end

      json(conn, StatusJSON.render_many(rows, viewer_id))
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /accounts/:id/followers

  def followers(conn, %{"id" => id} = params) do
    list_relations(conn, id, params, :followers)
  end

  ## GET /accounts/:id/following

  def following(conn, %{"id" => id} = params) do
    list_relations(conn, id, params, :following)
  end

  defp list_relations(conn, id, params, kind) do
    viewer_id = viewer_id(conn)
    limit = parse_limit(params["limit"])

    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Profiles.get_profile(int_id),
         :ok <- check_followers_visible(profile, viewer_id) do
      followers =
        case kind do
          :followers -> followers_of(profile.id, limit)
          :following -> following_of(profile.id, limit)
        end

      json(conn, Enum.map(followers, &Account.render/1))
    else
      {:error, :not_visible} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## Helpers

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      %{profile: %{id: id}} -> id
      _ -> nil
    end
  end

  defp author_visible_query(profile_id, nil) do
    from s in Status,
      where:
        s.profile_id == ^profile_id and is_nil(s.deleted_at) and
          s.visibility in [:public, :unlisted],
      preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []]
  end

  defp author_visible_query(profile_id, viewer_id) when profile_id == viewer_id do
    from s in Status,
      where: s.profile_id == ^profile_id and is_nil(s.deleted_at),
      preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []]
  end

  defp author_visible_query(profile_id, viewer_id) do
    follower? =
      Repo.exists?(
        from f in Angler.Follows.Follower,
          where:
            f.profile_id == ^profile_id and f.following_id == ^viewer_id and
              not is_nil(f.accepted_at)
      )

    if follower? do
      from s in Status,
        where:
          s.profile_id == ^profile_id and is_nil(s.deleted_at) and
            s.visibility in [:public, :unlisted, :private],
        preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []]
    else
      from s in Status,
        where:
          s.profile_id == ^profile_id and is_nil(s.deleted_at) and
            s.visibility in [:public, :unlisted],
        preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []]
    end
  end

  defp filter_account_options(q, params) do
    q
    |> exclude_replies(params["exclude_replies"])
    |> only_media_filter(params["only_media"])
  end

  defp exclude_replies(q, val) when val in ["true", "1", true] do
    from s in q, where: is_nil(s.in_reply_to_id)
  end

  defp exclude_replies(q, _), do: q

  defp only_media_filter(q, val) when val in ["true", "1", true] do
    from s in q, where: s.type in ["photo", "photo:album", "video", "video:album"]
  end

  defp only_media_filter(q, _), do: q

  defp followers_of(profile_id, limit) do
    Repo.all(
      from f in Angler.Follows.Follower,
        join: p in Profile,
        on: p.id == f.following_id,
        where: f.profile_id == ^profile_id and not is_nil(f.accepted_at) and is_nil(p.status),
        order_by: [desc: f.id],
        limit: ^limit,
        select: p
    )
  end

  defp following_of(profile_id, limit) do
    Repo.all(
      from f in Angler.Follows.Follower,
        join: p in Profile,
        on: p.id == f.profile_id,
        where: f.following_id == ^profile_id and not is_nil(f.accepted_at) and is_nil(p.status),
        order_by: [desc: f.id],
        limit: ^limit,
        select: p
    )
  end

  defp check_followers_visible(%Profile{is_private: false}, _viewer), do: :ok
  defp check_followers_visible(%Profile{id: id}, viewer) when id == viewer, do: :ok

  defp check_followers_visible(%Profile{id: id}, viewer) when not is_nil(viewer) do
    if Repo.exists?(
         from f in Angler.Follows.Follower,
           where: f.profile_id == ^id and f.following_id == ^viewer and not is_nil(f.accepted_at)
       ),
       do: :ok,
       else: {:error, :not_visible}
  end

  defp check_followers_visible(_, _), do: {:error, :not_visible}

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n |> max(1) |> min(80)
      _ -> 40
    end
  end

  defp parse_limit(_), do: 40

  defp current_url_without_cursor(conn) do
    qs =
      conn.query_params
      |> Map.drop(["max_id", "min_id", "since_id"])
      |> Plug.Conn.Query.encode()

    base = current_url(conn) |> URI.parse() |> Map.put(:query, nil) |> URI.to_string()
    if qs == "", do: base, else: base <> "?" <> qs
  end

  defp translate_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  ## POST /accounts/:id/remove_from_followers
  ##
  ## Yank a follower without notifying them — the inverse of an unfollow.
  ## Pixelfed exposes this as a mute-and-block-light: the relationship goes
  ## back to "neither follows the other".

  def remove_from_followers(conn, %{"id" => id}) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, target_id} <- parse_id(id),
         true <- target_id != actor.id || {:error, :self} do
      :ok = Follows.remove_inbound_follow(actor.id, target_id)
      respond_relationship(conn, actor.id, target_id)
    else
      {:error, :self} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => "target_id == self"})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## POST /accounts/:id/{pin,unpin} — Pixelfed endorsements
  ##
  ## We don't ship an endorsements table yet; both routes succeed as a no-op
  ## and return the current relationship so the mobile UI doesn't error.

  def endorse(conn, %{"id" => id}), do: noop_relationship(conn, id)
  def unendorse(conn, %{"id" => id}), do: noop_relationship(conn, id)

  defp noop_relationship(conn, id) do
    %{profile: actor} = BearerAuth.current_scope(conn)

    with {:ok, target_id} <- parse_id(id),
         %Profile{} <- Profiles.get_profile(target_id) do
      respond_relationship(conn, actor.id, target_id)
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /accounts/:id/lists — which lists this account is on
  ##
  ## Pixelfed's stub returns []; lists-membership is a list-side query that
  ## the mobile UI doesn't actually depend on. Keep parity.

  def account_lists(conn, _params), do: json(conn, [])

  ## POST /avatar/update
  ##
  ## Pixelfed-only direct avatar upload: a single multipart `avatar` field.
  ## We funnel it through the same `Profiles.update_credentials/2` path that
  ## handles `PATCH /accounts/update_credentials`.

  def avatar_update(conn, params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)
    upload = params["avatar"] || params["file"]

    cond do
      is_nil(upload) ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => "avatar is required"})

      true ->
        case Profiles.update_credentials(profile, %{"avatar" => upload}) do
          {:ok, updated} ->
            body =
              Account.render(updated)
              |> Map.put("source", source_block(user, updated))

            json(conn, body)

          {:error, %Ecto.Changeset{} = cs} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{"error" => "Validation failed", "errors" => translate_errors(cs)})

          {:error, :not_local_profile} ->
            conn |> put_status(:forbidden) |> json(%{"error" => "Not a local profile"})

          {:error, reason} ->
            conn |> put_status(:unprocessable_entity) |> json(%{"error" => to_string(reason)})
        end
    end
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

  defp render_opts(params, user) do
    case Map.get(params, "_pe") do
      v when v in ["1", "true", 1, true] -> [pe: true, user: user]
      _ -> []
    end
  end
end
