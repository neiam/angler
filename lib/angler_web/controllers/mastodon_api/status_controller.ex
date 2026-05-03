defmodule AnglerWeb.MastodonAPI.StatusController do
  @moduledoc """
  Mastodon-compatible status endpoints: show, create, plus the interaction
  set (favourite / unfavourite / reblog / unreblog / bookmark / unbookmark).

  `Idempotency-Key` header on POST /statuses is accept-and-ignore for now
  (TODO: small idempotency_keys table + Oban prune; documented in plans).
  """

  use AnglerWeb, :controller

  alias Angler.Bookmarks
  alias Angler.Statuses
  alias Angler.Statuses.{Pinning, Scheduled, Scheduling, Status}
  alias Angler.Statuses.Workers.StatusDeliver
  alias Angler.Timelines.Workers.FeedInsert
  alias AnglerWeb.MastodonAPI.ScheduledStatus, as: ScheduledStatusJSON
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /api/v1/statuses/:id

  def show(conn, %{"id" => id}) do
    with {:ok, snowflake} <- parse_id(id),
         %Status{} = status <- Statuses.get(snowflake),
         viewer_id = viewer_id(conn),
         true <- Statuses.visible_to?(status, viewer_id) || :forbidden do
      json(conn, StatusJSON.render(status, viewer_id))
    else
      :forbidden -> not_found(conn)
      _ -> not_found(conn)
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
        do_create(conn, profile, params)
    end
  end

  defp do_create(conn, profile, params) do
    case Statuses.create_local(profile, params) do
      {:ok, status} ->
        FeedInsert.enqueue(status.id)
        StatusDeliver.enqueue_for(status)

        conn
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

  def reblog(conn, params) do
    interact(conn, params, fn status, profile ->
      case Statuses.reblog(profile, status) do
        {:error, :unrebloggable} ->
          {:error, :unrebloggable}

        other ->
          other
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
         %Status{} = status <- Statuses.get(snowflake),
         true <- Statuses.visible_to?(status, profile.id) || :forbidden,
         {:ok, _updated} <- fun.(status, profile) do
      # Always re-render from a fresh read so counters + viewer overlay are
      # accurate after the action.
      fresh = Statuses.get(snowflake)
      json(conn, StatusJSON.render(fresh, profile.id))
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
