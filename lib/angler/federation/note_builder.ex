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
    {to, cc} = audience_uris(actor_url, status)

    %{
      "@context" => @context,
      "id" => status.uri || status.url,
      "type" => "Note",
      "attributedTo" => actor_url,
      "content" => status.rendered || "",
      "published" => published(status),
      "url" => status.url || status.uri,
      "to" => to,
      "cc" => cc,
      "sensitive" => status.is_nsfw,
      "summary" => status.cw_summary,
      "tag" => tag_array(status),
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
    {to, cc} = audience_uris(actor_url, status)

    %{
      "@context" => @context,
      "id" => (status.uri || status.url) <> "/activity",
      "type" => "Create",
      "actor" => actor_url,
      "published" => object["published"],
      "to" => to,
      "cc" => cc,
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

  defp audience_uris(actor_url, %Status{visibility: :public}),
    do: {[@public_uri], [actor_url <> "/followers"]}

  defp audience_uris(actor_url, %Status{visibility: :unlisted}),
    do: {[actor_url <> "/followers"], [@public_uri]}

  defp audience_uris(actor_url, %Status{visibility: :private}),
    do: {[actor_url <> "/followers"], []}

  defp audience_uris(_actor_url, %Status{visibility: :direct, id: status_id}) do
    mention_urls =
      from(m in Mention,
        where: m.status_id == ^status_id,
        join: p in Profile,
        on: p.id == m.profile_id,
        select: p.remote_url
      )
      |> Repo.all()
      |> Enum.reject(&is_nil/1)

    {mention_urls, []}
  end

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
