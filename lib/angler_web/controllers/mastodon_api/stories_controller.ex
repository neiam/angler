defmodule AnglerWeb.MastodonAPI.StoriesController do
  @moduledoc """
  Pixelfed Stories endpoints. The real implementation lives in the
  `Angler.Stories` context; this controller adapts request/response shape.

    * GET  /api/v1.1/stories/carousel
    * GET  /api/v1.1/stories/self-carousel
    * POST /api/v1.1/stories/add               — multipart `file`
    * POST /api/v1.1/stories/publish           — `media_id` + flags
    * POST /api/v1.1/stories/seen              — `id`
    * POST /api/v1.1/stories/self-expire/:id
    * POST /api/v1.1/stories/comment           — `sid` + `caption`

  Toggled by `:stories_enabled` config (default off — operators opt in).
  """

  use AnglerWeb, :controller

  alias Angler.Stories
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /carousel

  def carousel(conn, _params) do
    if Stories.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)
      json(conn, Stories.carousel(profile))
    else
      json(conn, %{"self" => [], "nodes" => []})
    end
  end

  ## GET /self-carousel

  def self_carousel(conn, _params) do
    if Stories.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)
      %{self: own, nodes: _} = Stories.carousel(profile)
      json(conn, own)
    else
      json(conn, [])
    end
  end

  ## POST /add

  def add(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    upload = Map.get(params, "file")

    cond do
      not Stories.enabled?() ->
        disabled(conn)

      is_nil(upload) ->
        validation_error(conn, "file is required")

      true ->
        case Stories.add(profile, upload, params) do
          {:ok, story} ->
            json(conn, %{
              "code" => 200,
              "msg" => "Successfully added",
              "media_id" => Integer.to_string(story.id),
              "media_url" => Stories.render_node(story, profile.id)["src"],
              "media_type" => story.type
            })

          {:error, :limit_reached} ->
            conn
            |> put_status(418)
            |> json(%{"error" => "You have reached your limit for new Stories today."})

          {:error, :unsupported_type} ->
            validation_error(conn, "unsupported media type")

          {:error, :no_file} ->
            validation_error(conn, "file is required")

          {:error, reason} ->
            validation_error(conn, to_string(reason))
        end
    end
  end

  ## POST /publish

  def publish(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    cond do
      not Stories.enabled?() ->
        disabled(conn)

      is_nil(params["media_id"]) ->
        validation_error(conn, "media_id is required")

      true ->
        case parse_id(params["media_id"]) do
          {:ok, id} ->
            case Stories.publish(profile, id, params) do
              {:ok, _story} ->
                json(conn, %{"code" => 200, "msg" => "Successfully published"})

              {:error, :not_found} ->
                not_found(conn)

              {:error, %Ecto.Changeset{} = cs} ->
                changeset_error(conn, cs)
            end

          _ ->
            validation_error(conn, "media_id is invalid")
        end
    end
  end

  ## POST /seen

  def seen(conn, params) do
    if Stories.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)

      case parse_id(params["id"]) do
        {:ok, id} ->
          case Stories.mark_seen(profile, id) do
            {:ok, _} ->
              json(conn, %{"code" => 200})

            {:error, :forbidden} ->
              conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

            {:error, _} ->
              not_found(conn)
          end

        _ ->
          validation_error(conn, "id is required")
      end
    else
      json(conn, %{})
    end
  end

  ## POST /self-expire/:id

  def self_expire(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    if Stories.enabled?() do
      case parse_id(id) do
        {:ok, sid} ->
          case Stories.delete(profile, sid) do
            :ok ->
              json(conn, %{"code" => 200})

            {:error, :forbidden} ->
              conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

            {:error, _} ->
              not_found(conn)
          end

        _ ->
          not_found(conn)
      end
    else
      json(conn, %{})
    end
  end

  ## GET /stories/viewers?sid=...

  def viewers(conn, params) do
    if Stories.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)

      with {:ok, sid} <- parse_id(params["sid"] || params["id"]),
           {:ok, %{viewers: list, next_max_id: next}} <-
             Stories.viewers(profile, sid, viewers_opts(params)) do
        json(conn, %{"viewers" => list, "next_max_id" => next})
      else
        :error ->
          validation_error(conn, "sid is required")

        {:error, :forbidden} ->
          conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

        {:error, :inactive} ->
          conn |> put_status(:not_found) |> json(%{"error" => "Story is no longer active"})

        {:error, _} ->
          not_found(conn)
      end
    else
      json(conn, %{"viewers" => [], "next_max_id" => nil})
    end
  end

  defp viewers_opts(params) do
    opts = []

    opts =
      case Integer.parse(to_string(params["limit"] || "")) do
        {n, ""} -> Keyword.put(opts, :limit, n)
        _ -> opts
      end

    case Integer.parse(to_string(params["max_id"] || "")) do
      {n, ""} -> Keyword.put(opts, :max_id, n)
      _ -> opts
    end
  end

  ## POST /comment

  def comment(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    cond do
      not Stories.enabled?() ->
        disabled(conn)

      not (is_binary(params["caption"]) and params["caption"] != "") ->
        validation_error(conn, "caption is required")

      true ->
        case parse_id(params["sid"]) do
          {:ok, sid} -> send_comment(conn, profile, sid, params["caption"])
          _ -> validation_error(conn, "sid is required")
        end
    end
  end

  defp send_comment(conn, profile, sid, caption) do
    case Stories.comment(profile, sid, caption) do
      {:ok, status} ->
        json(conn, %{
          "code" => 200,
          "msg" => "Successfully sent",
          "id" => Integer.to_string(status.id)
        })

      {:error, :replies_disabled} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "Replies are disabled for this story."})

      {:error, _} ->
        not_found(conn)
    end
  end

  ## Internals

  defp parse_id(nil), do: :error

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

  defp disabled(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{"error" => "Stories are not yet enabled on this instance."})
  end

  defp validation_error(conn, msg),
    do: conn |> put_status(:unprocessable_entity) |> json(%{"error" => msg})

  defp changeset_error(conn, cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "Validation failed", "errors" => errors})
  end
end
