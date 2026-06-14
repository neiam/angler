defmodule Angler.Federation.NoteBuilder do
  @moduledoc """
  Builds the canonical ActivityPub `Note` object (and the `Create` activity
  that wraps it) for a local status.

  Shared by outbound delivery (`Angler.Statuses.Workers.StatusDeliver`) and the
  AP object endpoint (`AnglerWeb.Plugs.APObjectNegotiation`) so the pushed
  activity and the dereferenceable object are byte-for-byte consistent — which
  matters because peers like Pixelfed re-fetch the object `id` to verify a
  pushed `Create`.
  """

  import Ecto.Query, warn: false

  alias Angler.Media.Storage
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{Mention, Status}

  @public_uri "https://www.w3.org/ns/activitystreams#Public"
  @context ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"]

  @doc "The standalone AP `Note` object (with `@context`) for a local status."
  @spec object(Status.t()) :: map()
  def object(%Status{} = status) do
    object(status, Repo.get!(Profile, status.profile_id))
  end

  @spec object(Status.t(), Profile.t()) :: map()
  def object(%Status{} = status, %Profile{} = actor) do
    actor_url = Profiles.actor_url(actor)
    parent = reply_context(status)
    {to, cc} = audience_uris(actor_url, status, parent)

    %{
      "@context" => @context,
      "id" => status.uri || status.url,
      "type" => "Note",
      "inReplyTo" => parent && parent.uri,
      "attributedTo" => actor_url,
      "content" => status.rendered || "",
      "published" => published(status),
      "url" => status.url || status.uri,
      "to" => to,
      "cc" => cc,
      "sensitive" => status.is_nsfw,
      "summary" => status.cw_summary,
      "tag" => Enum.uniq_by(tag_array(status) ++ parent_mention(parent), & &1["href"]),
      "attachment" => attachments(status)
    }
    |> drop_nils()
  end

  @doc """
  The AP `Create` activity wrapping the Note. The embedded object omits its own
  `@context` (it lives on the activity), per AS2 convention.
  """
  @spec create_activity(Status.t(), Profile.t()) :: map()
  def create_activity(%Status{} = status, %Profile{} = actor) do
    actor_url = Profiles.actor_url(actor)
    object = object(status, actor) |> Map.delete("@context")

    %{
      "@context" => @context,
      "id" => (status.uri || status.url) <> "/activity",
      "type" => "Create",
      "actor" => actor_url,
      "published" => object["published"],
      # Mirror the embedded object's addressing so the activity and object agree.
      "to" => object["to"] || [],
      "cc" => object["cc"] || [],
      "object" => object
    }
  end

  ## Internals

  defp published(%Status{inserted_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp published(_), do: DateTime.to_iso8601(DateTime.utc_now())

  defp attachments(%Status{} = status) do
    status = Repo.preload(status, :media_attachments)

    Enum.map(status.media_attachments, fn a ->
      %{
        "type" => "Document",
        "mediaType" => a.media_type,
        "url" => Storage.url(a, :original),
        "name" => a.caption,
        "blurhash" => a.blurhash,
        "width" => a.width,
        "height" => a.height
      }
      |> drop_nils()
    end)
  end

  # `parent` (a reply's parent context, or nil) addresses the replied-to author
  # so the reply reaches that account even when they don't follow us.
  defp audience_uris(actor_url, %Status{visibility: :public}, parent),
    do: {[@public_uri], Enum.uniq([actor_url <> "/followers"] ++ parent_cc(parent))}

  defp audience_uris(actor_url, %Status{visibility: :unlisted}, parent),
    do: {[actor_url <> "/followers"], Enum.uniq([@public_uri] ++ parent_cc(parent))}

  defp audience_uris(actor_url, %Status{visibility: :private}, parent),
    do: {Enum.uniq([actor_url <> "/followers"] ++ parent_cc(parent)), []}

  defp audience_uris(_actor_url, %Status{visibility: :direct, id: status_id}, parent) do
    mention_urls =
      from(m in Mention,
        where: m.status_id == ^status_id,
        join: p in Profile,
        on: p.id == m.profile_id,
        select: p.remote_url
      )
      |> Repo.all()
      |> Enum.reject(&is_nil/1)

    {Enum.uniq(mention_urls ++ parent_cc(parent)), []}
  end

  defp parent_cc(nil), do: []
  defp parent_cc(%{author_url: url}) when is_binary(url), do: [url]
  defp parent_cc(_), do: []

  # Resolve a reply's parent: its AP id (for `inReplyTo`) and author (for
  # addressing + a Mention tag). nil for top-level posts.
  defp reply_context(%Status{in_reply_to_id: nil}), do: nil

  defp reply_context(%Status{in_reply_to_id: parent_id}) do
    case Repo.get(Status, parent_id) do
      %Status{} = parent ->
        author = parent.profile_id && Repo.get(Profile, parent.profile_id)

        %{
          uri: parent.uri || parent.url,
          author: author,
          author_url: author && Profiles.actor_url(author)
        }

      _ ->
        nil
    end
  end

  defp parent_mention(%{author: %Profile{} = author, author_url: url}) when is_binary(url) do
    [
      %{
        "type" => "Mention",
        "name" => "@" <> author.username <> if(author.domain, do: "@" <> author.domain, else: ""),
        "href" => url
      }
    ]
  end

  defp parent_mention(_), do: []

  # AS2 `tag` array: Mention + Hashtag entries matching what we parse inbound,
  # so a round-trip through ourselves works.
  defp tag_array(%Status{} = status) do
    status = Repo.preload(status, [:mentions, status_hashtags: :hashtag])

    mentions =
      Enum.map(status.mentions, fn m ->
        profile = Repo.get!(Profile, m.profile_id)

        %{
          "type" => "Mention",
          "name" =>
            "@" <> profile.username <> if(profile.domain, do: "@" <> profile.domain, else: ""),
          "href" => Profiles.actor_url(profile)
        }
      end)

    hashtags =
      Enum.map(status.status_hashtags, fn sh ->
        %{
          "type" => "Hashtag",
          "name" => "#" <> sh.hashtag.name,
          "href" => AnglerWeb.Endpoint.url() <> "/tags/" <> sh.hashtag.name
        }
      end)

    mentions ++ hashtags
  end

  defp drop_nils(map), do: Map.reject(map, fn {_, v} -> is_nil(v) end)
end
