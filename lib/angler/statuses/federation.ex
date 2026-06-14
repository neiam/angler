defmodule Angler.Statuses.Federation do
  @moduledoc """
  Inbound activity handlers for Note-related verbs:
  `Create Note`, `Update Note`, `Delete Tombstone`.

  AS2 → `Status` row, including mentions and hashtags from the object's
  `tag` array. Local recipients of mentions are resolved by URL match
  against `<base>/users/<name>`.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Angler.Conversations
  alias Angler.Federation.Actor
  alias Angler.Hashtags
  alias Angler.Notifications
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.{Mention, Status, StatusHashtag}

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  Handle a `Create` activity whose `object.type` is `Note` (or `Question`).

  Returns `:ok` on success or `{:error, reason}`. Idempotent on object id.
  """
  @spec handle_create(map(), String.t()) :: :ok | {:error, term()}
  def handle_create(%{"object" => %{"type" => type, "id" => object_id} = object}, actor_url)
      when type in ["Note", "Question"] and is_binary(object_id) do
    case Statuses.get_by_uri(object_id) do
      %Status{} ->
        # Already mirrored.
        :ok

      nil ->
        do_create(object, actor_url)
    end
  end

  def handle_create(_, _), do: {:error, :unsupported_object_type}

  defp do_create(object, actor_url) do
    with {:ok, %Profile{} = author} <- Actor.resolve(actor_url),
         attrs = build_attrs(object, author),
         {:ok, status} <- Statuses.create_remote(attrs) do
      attach_media(status, object)
      attach_mentions(status, object)
      attach_hashtags(status, object)
      bump_author_count(status.profile_id)
      maybe_increment_reply_count(status)

      if status.visibility == :direct, do: Conversations.record(status)

      # Fan into local followers' home timelines. Skips :direct visibility.
      Angler.Timelines.Workers.FeedInsert.enqueue(status.id)

      :ok
    else
      {:error, %Ecto.Changeset{} = cs} ->
        Logger.warning("inbound Create Note rejected: #{inspect(cs.errors)}")
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Handle `Update Note` — refresh mutable fields on an already-mirrored status.

  Mastodon includes the full updated Note inline; we trust it.
  """
  @spec handle_update(map(), String.t()) :: :ok | {:error, term()}
  def handle_update(%{"object" => %{"type" => type, "id" => object_id} = object}, _actor_url)
      when type in ["Note", "Question"] and is_binary(object_id) do
    case Statuses.get_by_uri(object_id) do
      nil ->
        # Update for an unknown status — could indicate we missed the Create.
        # Optimistically materialize it as if it were a Create.
        Logger.info("Update Note for unknown status #{object_id}; treating as Create")
        do_create(object, object["attributedTo"])

      %Status{} = status ->
        edited_at =
          case object["updated"] do
            ts when is_binary(ts) ->
              case DateTime.from_iso8601(ts) do
                {:ok, dt, _} -> dt
                _ -> DateTime.utc_now()
              end

            _ ->
              DateTime.utc_now()
          end

        attrs = build_attrs(object, status.profile) |> Map.put(:edited_at, edited_at)

        status
        |> Status.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  def handle_update(_, _), do: {:error, :bad_update_payload}

  @doc """
  Handle `Delete Tombstone` — soft-delete the mirrored status.
  """
  @spec handle_delete_tombstone(String.t()) :: :ok
  def handle_delete_tombstone(object_id) when is_binary(object_id) do
    Statuses.soft_delete_by_uri(object_id)
    :ok
  end

  ## Internals

  defp build_attrs(object, %Profile{} = author) do
    visibility = visibility_from_audience(object)

    %{
      profile_id: author.id,
      caption: strip_html(object["content"] || ""),
      rendered: object["content"] || "",
      is_nsfw: object["sensitive"] == true,
      cw_summary: object["summary"],
      visibility: visibility,
      scope: Atom.to_string(visibility),
      type: type_from_attachments(object["attachment"]),
      pf_type: type_from_attachments(object["attachment"]),
      local: false,
      uri: object["id"],
      url: object["url"] || object["id"],
      in_reply_to_id: lookup_reply_target_id(object),
      in_reply_to_profile_id: lookup_reply_target_author_id(object),
      language: language_of(object)
    }
  end

  # `to`/`cc` mapping (Mastodon convention):
  #   to:[Public], cc:[followers] → :public
  #   to:[followers], cc:[] → :unlisted (Public missing, only followers)
  #   to:[mentions], cc:[] → :direct
  #   else → :private (only followers / locked)
  defp visibility_from_audience(object) do
    to = List.wrap(object["to"])
    cc = List.wrap(object["cc"])
    all = to ++ cc

    cond do
      @public_uri in to -> :public
      @public_uri in cc -> :unlisted
      all == [] -> :public
      Enum.all?(all, &String.ends_with?(&1, "/followers")) -> :private
      true -> :direct
    end
  end

  defp type_from_attachments(atts) when is_list(atts) and atts != [] do
    cond do
      Enum.all?(atts, &(media_kind(&1) == :image)) and length(atts) == 1 -> "photo"
      Enum.all?(atts, &(media_kind(&1) == :image)) -> "photo:album"
      Enum.all?(atts, &(media_kind(&1) == :video)) and length(atts) == 1 -> "video"
      Enum.all?(atts, &(media_kind(&1) == :video)) -> "video:album"
      true -> "text"
    end
  end

  defp type_from_attachments(_), do: "text"

  defp media_kind(%{"mediaType" => mt}) when is_binary(mt) do
    cond do
      String.starts_with?(mt, "image/") -> :image
      String.starts_with?(mt, "video/") -> :video
      true -> :other
    end
  end

  defp media_kind(_), do: :other

  defp language_of(%{"contentMap" => %{} = map}) do
    case Map.keys(map) do
      [first | _] -> first
      _ -> "en"
    end
  end

  defp language_of(_), do: "en"

  defp lookup_reply_target_id(%{"inReplyTo" => uri}) when is_binary(uri) do
    case Statuses.get_by_uri(uri) do
      %Status{id: id} -> id
      _ -> nil
    end
  end

  defp lookup_reply_target_id(_), do: nil

  defp lookup_reply_target_author_id(%{"inReplyTo" => uri}) when is_binary(uri) do
    case Statuses.get_by_uri(uri) do
      %Status{profile_id: pid} -> pid
      _ -> nil
    end
  end

  defp lookup_reply_target_author_id(_), do: nil

  ## Tag processing

  defp attach_media(%Status{} = status, object) do
    Angler.Media.ingest_remote_attachments(
      List.wrap(object["attachment"]),
      status.id,
      status.profile_id
    )

    :ok
  end

  defp attach_mentions(%Status{} = status, %{"tag" => tags}) when is_list(tags) do
    base_users = AnglerWeb.Endpoint.url() <> "/users/"

    tags
    |> Enum.filter(&(&1["type"] == "Mention" and is_binary(&1["href"])))
    |> Enum.map(& &1["href"])
    |> Enum.uniq()
    |> Enum.each(fn href ->
      cond do
        String.starts_with?(href, base_users) ->
          username = String.trim_leading(href, base_users)

          case Profiles.get_local_by_username(username) do
            %Profile{id: pid} ->
              insert_mention(status.id, pid)

              Notifications.notify(%{
                recipient_id: pid,
                account_id: status.profile_id,
                type: "mention",
                status_id: status.id
              })

            _ ->
              :ok
          end

        true ->
          # Remote mention — store iff we already have the actor cached.
          # We deliberately don't fetch here to avoid amplification.
          case Repo.get_by(Profile, remote_url: href) do
            %Profile{id: pid} -> insert_mention(status.id, pid)
            _ -> :ok
          end
      end
    end)
  end

  defp attach_mentions(_, _), do: :ok

  defp insert_mention(status_id, profile_id) do
    %{status_id: status_id, profile_id: profile_id}
    |> Mention.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:status_id, :profile_id])
  end

  defp attach_hashtags(%Status{} = status, %{"tag" => tags}) when is_list(tags) do
    tags
    |> Enum.filter(&(&1["type"] == "Hashtag" and is_binary(&1["name"])))
    |> Enum.map(&hashtag_name/1)
    |> Enum.uniq()
    |> Enum.each(fn name ->
      tag = Hashtags.ensure!(name)

      %{
        status_id: status.id,
        hashtag_id: tag.id,
        profile_id: status.profile_id,
        status_visibility: Atom.to_string(status.visibility)
      }
      |> StatusHashtag.changeset()
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:status_id, :hashtag_id])
    end)
  end

  defp attach_hashtags(_, _), do: :ok

  # `name` may come as `#tag` or `tag` — strip the leading `#`.
  defp hashtag_name(%{"name" => name}) do
    name |> String.trim_leading("#") |> String.downcase()
  end

  ## Counter housekeeping

  defp bump_author_count(profile_id) do
    Repo.update_all(
      from(p in Profile, where: p.id == ^profile_id),
      inc: [statuses_count: 1],
      set: [last_status_at: DateTime.utc_now()]
    )

    :ok
  end

  defp maybe_increment_reply_count(%Status{in_reply_to_id: nil}), do: :ok

  defp maybe_increment_reply_count(%Status{in_reply_to_id: parent}),
    do: Statuses.inc_counter(parent, :reply_count)

  ## Plain-text caption from HTML — minimal Floki-free version.
  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/&#39;/, "'")
    |> String.trim()
  end

  defp strip_html(_), do: ""
end
