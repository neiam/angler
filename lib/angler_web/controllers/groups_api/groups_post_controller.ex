defmodule AnglerWeb.GroupsAPI.GroupsPostController do
  @moduledoc """
  Posts + comments + likes scoped to a group on `/api/v0/groups/...`.

  We piggyback on the existing `Angler.Statuses` pipeline — group posts
  are statuses with `group_id` set; comments are statuses with
  `in_reply_to_id` pointing at a group post. The favourite/reblog/
  bookmark surface is unchanged because those actions key off the
  status, not the group.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Groups
  alias Angler.Groups.Group
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## Status (post) lifecycle

  def store_post(conn, params) do
    with_group(conn, params["id"] || params["group_id"], fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.post(actor, group, params) do
        {:ok, status} ->
          json(conn, StatusJSON.render(status, actor.id))

        {:error, :forbidden} ->
          forbidden(conn)

        {:error, :blocked} ->
          forbidden(conn)

        {:error, %Ecto.Changeset{} = cs} ->
          validation_error(conn, traverse(cs))

        {:error, reason} ->
          validation_error(conn, %{"error" => [to_string(reason)]})
      end
    end)
  end

  def delete_post(conn, params) do
    with_group(conn, params["id"] || params["group_id"], fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)
      sid = parse_id_or_nil(params["sid"] || params["status_id"])

      case Groups.delete_post(actor, group, sid) do
        :ok ->
          json(conn, %{"code" => 200})

        {:error, :forbidden} ->
          forbidden(conn)

        {:error, _} ->
          not_found(conn)
      end
    end)
  end

  def get_status(conn, params) do
    with_group(conn, params["id"] || params["group_id"], fn group ->
      sid = parse_id_or_nil(params["sid"] || params["status_id"])

      case sid && Repo.get(Status, sid) do
        nil ->
          not_found(conn)

        %Status{group_id: gid} when gid != group.id ->
          not_found(conn)

        %Status{} = status ->
          json(conn, StatusJSON.render(status, viewer_id(conn)))
      end
    end)
  end

  def media_list(conn, params) do
    # Pixelfed returns recent media-bearing posts for a group. We mount
    # the carousel-style read on top of the group feed.
    with_group(conn, params["id"] || params["group_id"], fn group ->
      viewer_id = viewer_id(conn)

      statuses =
        Groups.feed(group, viewer_id, 60)
        |> Enum.filter(fn %Status{type: t} ->
          String.starts_with?(t || "", "photo") or String.starts_with?(t || "", "video")
        end)

      json(conn, StatusJSON.render_many(statuses, viewer_id))
    end)
  end

  def show_status_likes(conn, params) do
    with_group(conn, params["id"], fn _group ->
      # Real likes list lives in the engagement-list code path on the
      # status itself; we surface an empty array here so clients don't
      # 404. Wire to `StatusController.favourited_by` later if needed.
      json(conn, [])
    end)
  end

  ## Likes (post-level)

  def like_post(conn, params), do: pipe_to_status(conn, params, &Statuses.favourite/2)
  def unlike_post(conn, params), do: pipe_to_status(conn, params, &Statuses.unfavourite/2)

  def comment_like(conn, params), do: pipe_to_status(conn, params, &Statuses.favourite/2)
  def comment_unlike(conn, params), do: pipe_to_status(conn, params, &Statuses.unfavourite/2)

  defp pipe_to_status(conn, params, fun) do
    if Groups.enabled?() do
      %{profile: actor} = BearerAuth.current_scope(conn)
      sid = parse_id_or_nil(params["sid"] || params["status_id"] || params["id"])

      case sid && Repo.get(Status, sid) do
        nil ->
          not_found(conn)

        %Status{} = s ->
          case fun.(actor, s) do
            {:ok, status} -> json(conn, StatusJSON.render(status, actor.id))
            {:error, _} -> validation_error(conn, %{"error" => ["could not apply"]})
          end
      end
    else
      not_found(conn)
    end
  end

  ## Comments
  ##
  ## A group comment is a `:public` status replying to a group post.
  ## We thread it through the standard reply pipeline so notifications
  ## and rendering work unchanged.

  def comments_list(conn, params) do
    with_group(conn, params["id"] || params["group_id"], fn _group ->
      sid = parse_id_or_nil(params["sid"] || params["status_id"])

      case sid do
        nil ->
          json(conn, [])

        _ ->
          replies =
            Repo.all(
              from s in Status,
                where: s.in_reply_to_id == ^sid and is_nil(s.deleted_at),
                order_by: [asc: s.id],
                limit: 100
            )
            |> Repo.preload([
              :profile,
              mentions: :profile,
              status_hashtags: :hashtag,
              media_attachments: []
            ])

          json(conn, StatusJSON.render_many(replies, viewer_id(conn)))
      end
    end)
  end

  def store_comment(conn, params) do
    with_group(conn, params["id"] || params["group_id"], fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)
      parent_id = parse_id_or_nil(params["sid"] || params["status_id"])

      cond do
        is_nil(parent_id) ->
          validation_error(conn, %{"sid" => ["is required"]})

        not Groups.member?(group, actor) ->
          forbidden(conn)

        true ->
          create_comment(conn, actor, group, parent_id, params)
      end
    end)
  end

  defp create_comment(conn, actor, group, parent_id, params) do
    attrs = %{
      "status" => to_string(params["caption"] || params["status"] || ""),
      "in_reply_to_id" => Integer.to_string(parent_id),
      "visibility" => "public",
      "group_id" => Integer.to_string(group.id)
    }

    case Statuses.create_local(actor, attrs) do
      {:ok, status} -> json(conn, StatusJSON.render(status, actor.id))
      {:error, %Ecto.Changeset{} = cs} -> validation_error(conn, traverse(cs))
      {:error, reason} -> validation_error(conn, %{"error" => [to_string(reason)]})
    end
  end

  def store_comment_photo(conn, params) do
    # Same as store_comment from the API surface's perspective — the
    # mobile UI POSTs media via `/api/v1/media` first and includes the
    # returned id alongside the caption. Reuse store_comment.
    store_comment(conn, params)
  end

  def delete_comment(conn, params), do: delete_post(conn, params)

  ## Internals

  defp with_group(conn, id, fun) do
    if Groups.enabled?() do
      case Groups.get(id) do
        nil -> not_found(conn)
        %Group{} = g -> fun.(g)
      end
    else
      not_found(conn)
    end
  end

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      %{profile: %{id: pid}} -> pid
      _ -> nil
    end
  end

  defp parse_id_or_nil(nil), do: nil
  defp parse_id_or_nil(n) when is_integer(n), do: n

  defp parse_id_or_nil(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id_or_nil(_), do: nil

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})

  defp forbidden(conn),
    do: conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})

  defp traverse(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
