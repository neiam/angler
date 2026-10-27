defmodule AnglerWeb.MastodonAPI.StatusController do
  @moduledoc """
  Mastodon-compatible status endpoints: show, create, plus the interaction
  set (favourite / unfavourite / reblog / unreblog / bookmark / unbookmark).

  `Idempotency-Key` on POST /statuses returns the original status for a
  repeat and 409 while the first request is still running
  (`Angler.Statuses.Idempotency`).
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Bookmarks
  alias Angler.Reblogs
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.{Idempotency, Pinning, Scheduled, Scheduling, Status}
  alias Angler.Statuses.Workers.StatusDeliver
  alias Angler.Timelines.Workers.FeedInsert
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.ScheduledStatus, as: ScheduledStatusJSON
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /api/v1/statuses/:id/{reblogged_by,favourited_by}

  def reblogged_by(conn, %{"id" => id}), do: engagement_list(conn, id, :reblog)
  def favourited_by(conn, %{"id" => id}), do: engagement_list(conn, id, :like)

  ## GET /statuses/:id/card — link preview card
  ##
  ## We don't crawl outbound URLs for OG metadata (Pixelfed dispatches
  ## that asynchronously). Match Pixelfed's stubbed empty-object response
  ## so clients that opportunistically request the card don't trip a 404.
  def card(conn, _params), do: json(conn, %{})

  defp engagement_list(conn, id, kind) do
    viewer_id = viewer_id(conn)

    with {:ok, snowflake} <- parse_id(id),
         %Status{} = status <- Statuses.get(snowflake),
         true <- Statuses.visible_to?(status, viewer_id) || :forbidden do
      profiles = engagement_profiles(status.id, kind)
      json(conn, Enum.map(profiles, &Account.render/1))
    else
      _ -> not_found(conn)
    end
  end

  defp engagement_profiles(status_id, :like) do
    Repo.all(
      from l in Angler.Likes.Like,
        join: p in Angler.Profiles.Profile,
        on: p.id == l.profile_id and is_nil(p.status),
        where: l.status_id == ^status_id,
        order_by: [desc: l.id],
        limit: 80,
        select: p
    )
  end

  defp engagement_profiles(status_id, :reblog) do
    Repo.all(
      from r in Angler.Reblogs.Reblog,
        join: p in Angler.Profiles.Profile,
        on: p.id == r.profile_id and is_nil(p.status),
        where: r.status_id == ^status_id,
        order_by: [desc: r.id],
        limit: 80,
        select: p
    )
  end

  ## GET /api/v1/statuses/:id

  def show(conn, %{"id" => id}) do
    with {:ok, snowflake} <- parse_id(id),
         item when not is_nil(item) <-
           Statuses.get(snowflake) || Reblogs.get_by_wrapper_id(snowflake),
         viewer_id = viewer_id(conn),
         true <- Statuses.visible_to?(boosted(item), viewer_id) || :forbidden do
      json(conn, StatusJSON.render(item, viewer_id))
    else
      :forbidden -> not_found(conn)
      _ -> not_found(conn)
    end
  end

  defp boosted(%Angler.Reblogs.Reblog{status: status}), do: status
  defp boosted(%Status{} = status), do: status

  # Clients act on whichever id they were shown; a boost's wrapper id means
  # the post it boosts.
  defp get_target(id) do
    case Statuses.get(id) do
      %Status{} = status ->
        status

      nil ->
        case Reblogs.get_by_wrapper_id(id) do
          %{status: %Status{id: sid}} -> Statuses.get(sid)
          nil -> nil
        end
    end
  end

  ## DELETE /api/v1/statuses/:id

  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, snowflake} <- parse_id(id),
         {:ok, deleted} <- Statuses.delete_local(snowflake, profile) do
      json(conn, StatusJSON.render(deleted, profile.id))
    else
      {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})
      _ -> not_found(conn)
    end
  end

  ## PUT /api/v1/statuses/:id

  def update(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, snowflake} <- parse_id(id),
         {:ok, updated} <- Statuses.update_local(snowflake, profile, params) do
      Angler.Statuses.Workers.StatusUpdateDeliver.enqueue_for(updated)
      json(conn, StatusJSON.render(updated, profile.id))
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "Validation failed", "errors" => format_changeset(cs)})

      _ ->
        not_found(conn)
    end
  end

  ## GET /api/v1/statuses/:id/history

  def history(conn, %{"id" => id}) do
    viewer_id = viewer_id(conn)

    with {:ok, snowflake} <- parse_id(id),
         %Status{} = status <- Statuses.get(snowflake),
         true <- Statuses.visible_to?(status, viewer_id) || :forbidden do
      edits = Statuses.edit_history(status.id)
      account = AnglerWeb.MastodonAPI.Account.render(status.profile)

      # Include the live row as the most recent edit if there are any prior
      # snapshots — Mastodon includes the current state in /history.
      live = %{
        "content" => status.rendered || "",
        "spoiler_text" => status.cw_summary || "",
        "sensitive" => status.is_nsfw,
        "created_at" => DateTime.to_iso8601(status.edited_at || status.inserted_at),
        "account" => account,
        "media_attachments" => [],
        "emojis" => []
      }

      historical =
        Enum.map(edits, fn e ->
          %{
            "content" => e.rendered || "",
            "spoiler_text" => e.spoiler_text || "",
            "sensitive" => e.is_nsfw,
            "created_at" => DateTime.to_iso8601(e.inserted_at),
            "account" => account,
            "media_attachments" => [],
            "emojis" => []
          }
        end)

      json(conn, historical ++ if(historical == [], do: [], else: [live]))
    else
      _ -> not_found(conn)
    end
  end

  ## GET /api/v1/statuses/:id/source

  def source(conn, %{"id" => id}) do
    viewer_id = viewer_id(conn)

    with {:ok, snowflake} <- parse_id(id),
         %Status{} = status <- Statuses.get(snowflake),
         true <- Statuses.visible_to?(status, viewer_id) || :forbidden do
      json(conn, %{
        "id" => Integer.to_string(status.id),
        "text" => status.caption || "",
        "spoiler_text" => status.cw_summary || ""
      })
    else
      _ -> not_found(conn)
    end
  end

  ## POST /api/v1/statuses/:id/pin
  ## POST /api/v1/statuses/:id/unpin

  def pin(conn, %{"id" => id}), do: pin_op(conn, id, :pin)
  def unpin(conn, %{"id" => id}), do: pin_op(conn, id, :unpin)

  defp pin_op(conn, id, op) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, snowflake} <- parse_id(id),
         %Status{} = status <- Statuses.get(snowflake) do
      case op do
        :pin ->
          case Pinning.pin(profile, status) do
            {:ok, _} ->
              json(conn, StatusJSON.render(status, profile.id))

            {:error, :forbidden} ->
              conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

            {:error, :unpinnable} ->
              validation_error(conn, "Cannot pin a private or direct status")

            {:error, :limit_reached} ->
              validation_error(conn, "Pin limit reached")
          end

        :unpin ->
          :ok = Pinning.unpin(profile, status)
          json(conn, StatusJSON.render(status, profile.id))
      end
    else
      _ -> not_found(conn)
    end
  end

  ## GET /api/v1/statuses/:id/context

  def context(conn, %{"id" => id}) do
    viewer_id = viewer_id(conn)

    with {:ok, snowflake} <- parse_id(id),
         %Status{} = status <- Statuses.get(snowflake),
         true <- Statuses.visible_to?(status, viewer_id) || :forbidden do
      ancestors = Statuses.ancestors(status, viewer_id)
      descendants = Statuses.descendants(status, viewer_id)

      json(conn, %{
        "ancestors" => StatusJSON.render_many(ancestors, viewer_id),
        "descendants" => StatusJSON.render_many(descendants, viewer_id)
      })
    else
      _ -> not_found(conn)
    end
  end

  ## POST /api/v1/statuses

  def create(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    cond do
      Scheduling.scheduled?(params) ->
        case Scheduling.schedule(profile, params) do
          {:ok, %Scheduled{} = row} -> json(conn, ScheduledStatusJSON.render(row))
          {:error, reason} -> validation_error(conn, to_string(reason))
        end

      true ->
        with_idempotency(conn, &do_create(&1, profile, params))
    end
  end

  defp with_idempotency(conn, create) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)

    case get_req_header(conn, "idempotency-key") do
      [key | _] when key != "" ->
        case Idempotency.claim(user.id, key) do
          :claimed ->
            conn = create.(conn)

            if conn.status == 200 and is_integer(conn.assigns[:created_status_id]) do
              Idempotency.complete(user.id, key, conn.assigns.created_status_id)
            else
              Idempotency.release(user.id, key)
            end

            conn

          {:existing, status_id} ->
            case Statuses.get(status_id) do
              %Status{deleted_at: nil} = status ->
                json(conn, StatusJSON.render(status, profile.id))

              _ ->
                # The original was deleted since; post anew.
                Idempotency.release(user.id, key)
                create.(conn)
            end

          :in_flight ->
            conn |> put_status(:conflict) |> json(%{"error" => "Request already in progress."})
        end

      _ ->
        create.(conn)
    end
  end

  defp do_create(conn, profile, params) do
    case Statuses.create_local(profile, params) do
      {:ok, status} ->
        FeedInsert.enqueue(status.id)
        StatusDeliver.enqueue_for(status)

        conn
        |> assign(:created_status_id, status.id)
        |> put_status(:ok)
        |> json(StatusJSON.render(status, profile.id))

      {:error, :empty_status} ->
        validation_error(conn, "Status is required")

      {:error, :bad_caption} ->
        validation_error(conn, "Status must be a string")

      {:error, :bad_visibility} ->
        validation_error(conn, "Visibility must be one of: public, unlisted, private, direct")

      {:error, :reply_parent_not_found} ->
        validation_error(conn, "Reply target not found")

      {:error, :reply_parent_not_visible} ->
        validation_error(conn, "Reply target not visible")

      {:error, :bad_reply_parent_id} ->
        validation_error(conn, "Reply target id is invalid")

      {:error, :not_local_profile} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Not a local account"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "Validation failed", "errors" => format_changeset(cs)})
    end
  end

  ## Interactions
  #
  # Each respects the visibility rule: you can only act on a status you can
  # actually see (i.e., `Statuses.visible_to?/2`). Non-visible → 404.

  def favourite(conn, params) do
    interact(conn, params, fn status, profile ->
      Statuses.favourite(profile, status)
    end)
  end

  def unfavourite(conn, params) do
    interact(conn, params, fn status, profile ->
      Statuses.unfavourite(profile, status)
    end)
  end

  # Mastodon answers a boost with the new wrapper status.
  def reblog(conn, params) do
    interact(conn, params, fn status, profile ->
      with {:ok, _} <- Statuses.reblog(profile, status) do
        {:ok, Repo.get_by!(Angler.Reblogs.Reblog, profile_id: profile.id, status_id: status.id)}
      end
    end)
  end

  def unreblog(conn, params) do
    interact(conn, params, fn status, profile ->
      Statuses.unreblog(profile, status)
    end)
  end

  def bookmark(conn, params) do
    interact(conn, params, fn status, profile ->
      with {:ok, _bookmark} <- Bookmarks.bookmark(profile.id, status.id) do
        {:ok, status}
      end
    end)
  end

  def unbookmark(conn, params) do
    interact(conn, params, fn status, profile ->
      :ok = Bookmarks.unbookmark(profile.id, status.id)
      {:ok, status}
    end)
  end

  ## Internals

  defp interact(conn, %{"id" => id}, fun) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, snowflake} <- parse_id(id),
         %Status{} = status <- get_target(snowflake),
         true <- Statuses.visible_to?(status, profile.id) || :forbidden,
         {:ok, updated} <- fun.(status, profile) do
      # Always re-render from a fresh read so counters + viewer overlay are
      # accurate after the action. A boost answers with its wrapper.
      fresh = Statuses.get(status.id)

      case updated do
        %Angler.Reblogs.Reblog{} = reblog ->
          json(conn, StatusJSON.render(%{reblog | status: fresh}, profile.id))

        _ ->
          json(conn, StatusJSON.render(fresh, profile.id))
      end
    else
      :forbidden ->
        not_found(conn)

      nil ->
        not_found(conn)

      {:error, :unrebloggable} ->
        validation_error(conn, "This status cannot be reblogged")

      {:error, reason} when is_atom(reason) ->
        validation_error(conn, Atom.to_string(reason))

      _ ->
        not_found(conn)
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      nil -> nil
      %{profile: %{id: id}} -> id
    end
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
  end

  defp validation_error(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{"error" => message})
  end

  defp format_changeset(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
