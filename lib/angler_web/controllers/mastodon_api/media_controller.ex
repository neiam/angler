defmodule AnglerWeb.MastodonAPI.MediaController do
  @moduledoc """
  Mastodon-shape media endpoints.

    * POST /api/v1/media — synchronous-shape (returns 200 immediately).
    * POST /api/v2/media — async-shape (returns 202).
    * GET  /api/v1/media/:id — poll-friendly read.
    * PUT  /api/v1/media/:id — update caption (alt text).
  """

  use AnglerWeb, :controller

  alias Angler.Media
  alias AnglerWeb.MastodonAPI.Media, as: MediaJSON
  alias AnglerWeb.Plugs.BearerAuth

  def upload_v1(conn, params) do
    do_upload(conn, params, 200)
  end

  def upload_v2(conn, params) do
    do_upload(conn, params, 202)
  end

  defp do_upload(conn, params, success_status) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    case Map.get(params, "file") do
      nil ->
        send_error(conn, 422, "file is required")

      upload ->
        case Media.upload(profile, upload, params) do
          {:ok, asset} ->
            conn |> put_status(success_status) |> json(MediaJSON.render(asset))

          {:error, :too_large} ->
            send_error(conn, 413, "file too large")

          {:error, :account_size_limit} ->
            send_error(conn, 403, "Account size limit reached.")

          {:error, :unsupported_type} ->
            send_error(conn, 422, "unsupported media type")

          {:error, :no_file} ->
            send_error(conn, 422, "file is required")

          {:error, reason} ->
            send_error(conn, 422, "upload failed: #{inspect(reason)}")
        end
    end
  end

  def show(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    case parse_id(id) do
      {:ok, int_id} ->
        case Media.get(int_id) do
          nil ->
            send_error(conn, 404, "Record not found")

          asset ->
            cond do
              asset.profile_id != profile.id and is_nil(asset.status_id) ->
                send_error(conn, 404, "Record not found")

              asset.status == "ready" ->
                json(conn, MediaJSON.render(asset))

              true ->
                conn |> put_status(206) |> json(MediaJSON.render(asset))
            end
        end

      _ ->
        send_error(conn, 404, "Record not found")
    end
  end

  def update(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = asset <- Media.get_owned(int_id, profile.id),
         {:ok, updated} <- Media.update_caption(asset, profile, params["description"]) do
      json(conn, MediaJSON.render(updated))
    else
      nil -> send_error(conn, 404, "Record not found")
      :error -> send_error(conn, 404, "Record not found")
      {:error, :forbidden} -> send_error(conn, 403, "Forbidden")
      {:error, _} -> send_error(conn, 422, "update failed")
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

  defp send_error(conn, status, msg) do
    conn |> put_status(status) |> json(%{"error" => msg})
  end
end
