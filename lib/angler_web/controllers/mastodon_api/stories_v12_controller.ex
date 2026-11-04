defmodule AnglerWeb.MastodonAPI.StoriesV12Controller do
  @moduledoc """
  Pixelfed `/api/v1.2/stories/...` namespace — the newer story endpoints
  the mobile app uses for the redesigned composer flow.

    * GET  /api/v1.2/stories/carousel             — `nodes`-only carousel
    * POST /api/v1.2/stories/publish              — combined add+publish
                                                    with overlays
    * GET  /api/v1.2/stories/mention-autocomplete — username prefix search
                                                    over the author's
                                                    followers

  All three respect `:stories_enabled` (404 when off, matching Pixelfed).
  """

  use AnglerWeb, :controller

  alias Angler.Stories
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /carousel — nodes-only

  def carousel_next(conn, _params) do
    if Stories.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)
      %{nodes: nodes} = Stories.carousel(profile)
      json(conn, %{"nodes" => nodes})
    else
      not_found(conn)
    end
  end

  ## POST /publish — combined add+publish with overlays

  def publish_next(conn, params) do
    cond do
      not Stories.enabled?() ->
        not_found(conn)

      is_nil(params["image"]) ->
        validation_error(conn, %{"image" => ["is required"]})

      true ->
        %{profile: profile} = BearerAuth.current_scope(conn)
        overlays = normalize_overlays(params["overlays"])

        case Stories.publish_next(profile, params["image"], overlays) do
          {:ok, _story} ->
            json(conn, %{"code" => 200, "msg" => "Successfully added"})

          {:error, reason} ->
            publish_error(conn, reason)
        end
    end
  end

  defp publish_error(conn, :limit_reached) do
    conn
    |> put_status(418)
    |> json(%{
      "code" => 418,
      "error" => "You've reached your daily limit of new Stories."
    })
  end

  defp publish_error(conn, :too_many_overlays),
    do: validation_error(conn, %{"overlays" => ["maximum 4 overlays per story"]})

  defp publish_error(conn, :unsupported_type),
    do: validation_error(conn, %{"image" => ["unsupported media type"]})

  defp publish_error(conn, :no_file), do: validation_error(conn, %{"image" => ["is required"]})

  defp publish_error(conn, {:invalid_overlay, idx, reason}) do
    validation_error(conn, %{
      "overlays.#{idx}.content" => [overlay_error_message(reason)]
    })
  end

  defp publish_error(conn, %Ecto.Changeset{} = cs), do: validation_error(conn, traverse(cs))

  defp publish_error(conn, reason),
    do: validation_error(conn, %{"error" => [to_string(reason)]})

  ## GET /mention-autocomplete

  def mention_autocomplete(conn, params) do
    cond do
      not Stories.enabled?() ->
        not_found(conn)

      not is_binary(params["q"]) or String.trim(params["q"]) == "" ->
        validation_error(conn, %{"q" => ["is required"]})

      String.length(params["q"]) > 120 ->
        validation_error(conn, %{"q" => ["is too long"]})

      true ->
        %{profile: profile} = BearerAuth.current_scope(conn)

        body =
          profile
          |> Stories.mention_autocomplete(params["q"])
          |> Enum.map(&Account.render/1)

        json(conn, body)
    end
  end

  ## Internals

  defp normalize_overlays(nil), do: []
  defp normalize_overlays(list) when is_list(list), do: list

  defp normalize_overlays(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> integer_key(k) end)
    |> Enum.map(fn {_, v} -> v end)
  end

  defp normalize_overlays(_), do: []

  defp integer_key(k) when is_integer(k), do: k

  defp integer_key(k) when is_binary(k) do
    case Integer.parse(k) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp integer_key(_), do: 0

  defp overlay_error_message(:bad_type), do: "Invalid overlay type."
  defp overlay_error_message(:bad_text), do: "Text overlays contain unsupported characters."
  defp overlay_error_message(:bad_hashtag), do: "Invalid hashtag overlay."
  defp overlay_error_message(:bad_url), do: "Only HTTPS URLs are allowed."
  defp overlay_error_message(:empty_mention), do: "Mention is empty."
  defp overlay_error_message(:unknown_mention), do: "The mentioned user does not exist."
  defp overlay_error_message(:bad_content), do: "Invalid overlay content."
  defp overlay_error_message(:not_a_map), do: "Overlay must be an object."
  defp overlay_error_message(other), do: to_string(other)

  defp traverse(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})
end
