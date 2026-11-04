defmodule AnglerWeb.MastodonAPI.CollectionController do
  @moduledoc """
  Pixelfed `/api/v1.1/collections/*`:

    * GET    /accounts/:id        — public collections for that profile
    * GET    /self                — own collections (incl. drafts) with items
    * GET    /view/:id            — fetch one (visibility-checked)
    * GET    /items/:id           — paginated items
    * POST   /add                 — create an empty draft
    * POST   /update/:id          — patch title/description/visibility
    * DELETE /delete/:id          — delete
    * POST   /storeId             — `{collection_id, post_id}` add an item
    * POST   /remove              — `{collection_id, post_id}` remove an item
  """

  use AnglerWeb, :controller

  alias Angler.Collections
  alias Angler.Collections.Collection
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## Reads

  def for_account(conn, %{"id" => id}) do
    viewer_id = viewer_id(conn)

    case parse_id(id) do
      {:ok, int_id} ->
        json(
          conn,
          Collections.for_profile(int_id, viewer_id) |> Enum.map(&render_one/1)
        )

      _ ->
        not_found(conn)
    end
  end

  def for_self(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    body =
      Collections.for_self(profile.id)
      |> Enum.map(fn c ->
        items =
          Collections.items(c, Collections.max_items())
          |> StatusJSON.render_many(profile.id)

        Map.put(render_one(c), "items", items)
      end)

    json(conn, body)
  end

  def view(conn, %{"id" => id}) do
    viewer_id = viewer_id(conn)

    with {:ok, int_id} <- parse_id(id),
         %Collection{} = c <- Collections.get(int_id),
         true <- Collections.visible_to?(c, viewer_id) || :forbidden do
      json(conn, render_one(c))
    else
      _ -> not_found(conn)
    end
  end

  def items(conn, %{"id" => id} = params) do
    viewer_id = viewer_id(conn)
    page = params["page"] |> parse_page()

    with {:ok, int_id} <- parse_id(id),
         %Collection{} = c <- Collections.get(int_id),
         true <- Collections.visible_to?(c, viewer_id) || :forbidden do
      offset = (page - 1) * 10
      statuses = Collections.items(c, 10, offset)
      json(conn, StatusJSON.render_many(statuses, viewer_id))
    else
      _ -> not_found(conn)
    end
  end

  ## Writes

  # Upstream routes `collections/add` to `storeId`: add `post_id` to
  # `collection_id` — it's what the app calls when you add a post to a
  # collection. A bare call (no ids) still creates a draft collection.
  def add(conn, %{"collection_id" => _, "post_id" => _} = params), do: store_id(conn, params)

  def add(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    {:ok, c} = Collections.create(profile.id)
    json(conn, render_one(c))
  end

  def update(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %Collection{profile_id: pid} = c when pid == profile.id <- Collections.get(int_id),
         {:ok, updated} <- Collections.update(c, params) do
      json(conn, render_one(updated))
    else
      {:error, cs} -> validation_error(conn, cs)
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %Collection{profile_id: pid} = c when pid == profile.id <- Collections.get(int_id) do
      :ok = Collections.delete(c)
      json(conn, 200)
    else
      _ -> not_found(conn)
    end
  end

  def store_id(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, cid} <- parse_id(params["collection_id"]),
         {:ok, sid} <- parse_id(params["post_id"]),
         %Collection{} = c <- Collections.get(cid),
         {:ok, status} <- Collections.add_item(c, profile, sid) do
      json(conn, StatusJSON.render(status, profile.id))
    else
      {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})
      {:error, :unaddable} -> validation_error_msg(conn, "must be a public photo or video status")
      {:error, :limit_reached} -> validation_error_msg(conn, "collection limit reached")
      _ -> not_found(conn)
    end
  end

  def delete_id(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, cid} <- parse_id(params["collection_id"]),
         {:ok, sid} <- parse_id(params["post_id"]),
         %Collection{} = c <- Collections.get(cid),
         :ok <- Collections.remove_item(c, profile, sid) do
      json(conn, 200)
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

      {:error, :last_item} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => "You cannot delete the only post of a collection"})

      _ ->
        not_found(conn)
    end
  end

  ## Internals

  defp render_one(%Collection{} = c) do
    %{
      "id" => Integer.to_string(c.id),
      "pid" => Integer.to_string(c.profile_id),
      "title" => c.title || "",
      "description" => c.description || "",
      "visibility" => c.visibility,
      "published_at" => format_ts(c.published_at),
      "updated_at" => format_ts(c.updated_at),
      "post_count" => Collections.item_count(c)
    }
  end

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      %{profile: %{id: id}} -> id
      _ -> nil
    end
  end

  defp parse_id(nil), do: :error

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp parse_page(nil), do: 1
  defp parse_page(v) when is_integer(v), do: v |> max(1)

  defp parse_page(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> max(n, 1)
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

  defp validation_error_msg(conn, msg),
    do: conn |> put_status(:unprocessable_entity) |> json(%{"error" => msg})

  defp validation_error(conn, %Ecto.Changeset{} = cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "Validation failed", "errors" => errors})
  end
end
