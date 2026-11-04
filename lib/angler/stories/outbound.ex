defmodule Angler.Stories.Outbound do
  @moduledoc """
  Outbound federated stories, as upstream StoryPipeline and its verbs:

    * `published/1` — `Add` of a local story to the author's remote
      followers, carrying only a bearcap (`CreateStory`, `StoryFanout`).
      They fetch the object from `GET /stories/:username/:id` with it.
    * `removed/1` — `Delete` of a local story to the same audience, when the
      author takes it down or it expires (`DeleteStory`, `StoryDelete`,
      `StoryExpire::fanoutExpiry`).
    * `viewed/2` — `View` of a remote story by a local follower, to its
      author (`StoryViewDeliver`).
    * `interacted/3` — `Story:Reaction` / `Story:Reply` from a local
      follower, to the remote author (`StoryReactionDeliver`,
      `StoryReplyDeliver`).

  Upstream only fans out to Pixelfed instances; we don't track peer
  software, so it goes to every remote follower's inbox and other servers
  ignore the unknown `Story` type. Nothing goes out while stories are off.
  """

  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{OutboundAudience, Status}
  alias Angler.Stories
  alias Angler.Stories.Story
  alias Angler.Stories.Workers.StoryDeliver

  @as "https://www.w3.org/ns/activitystreams"

  @doc "A local story's AS2 id, `/stories/:username/:id`."
  @spec url(Story.t(), Profile.t()) :: String.t()
  def url(%Story{id: id}, %Profile{username: username}),
    do: AnglerWeb.Endpoint.url() <> "/stories/" <> username <> "/" <> Integer.to_string(id)

  @doc "The `Story` object served behind the bearcap (upstream StoryVerb)."
  @spec object(Story.t(), Profile.t()) :: map()
  def object(%Story{} = story, %Profile{} = author) do
    actor = Profiles.actor_url(author)

    %{
      "@context" => @as,
      "id" => url(story, author),
      "type" => "Story",
      "to" => [actor <> "/followers"],
      "cc" => [],
      "attributedTo" => actor,
      "published" => DateTime.to_iso8601(story.inserted_at),
      "expiresAt" => DateTime.to_iso8601(story.expires_at),
      "duration" => div(story.duration_ms, 1000),
      "can_reply" => story.can_reply,
      "can_react" => story.can_react,
      "attachment" => %{
        "type" => if(story.type == "video", do: "Video", else: "Image"),
        "url" => Stories.media_url(story),
        "mediaType" => story.mime
      }
    }
  end

  @spec published(Story.t()) :: :ok
  def published(%Story{local: true, active: true, bearcap_token: token} = story)
      when is_binary(token) do
    with_author(story, fn author ->
      story_url = url(story, author)
      actor = Profiles.actor_url(author)

      fan_out(author, %{
        "@context" => @as,
        "id" => story_url <> "/activity",
        "type" => "Add",
        "actor" => actor,
        "to" => [actor <> "/followers"],
        "object" => %{
          "id" => story_url,
          "type" => "Story",
          "object" => "bear:?t=" <> token <> "&u=" <> story_url
        }
      })
    end)
  end

  def published(_), do: :ok

  @spec removed(Story.t()) :: :ok
  def removed(%Story{local: true} = story) do
    with_author(story, fn author ->
      story_url = url(story, author)

      fan_out(author, %{
        "@context" => @as,
        "id" => story_url <> "#delete",
        "type" => "Delete",
        "actor" => Profiles.actor_url(author),
        "object" => %{"id" => story_url, "type" => "Story"}
      })
    end)
  end

  def removed(_), do: :ok

  @spec viewed(Story.t(), Profile.t()) :: :ok
  def viewed(%Story{local: false, remote_url: object_id} = story, %Profile{domain: nil} = viewer)
      when is_binary(object_id) do
    with_author(story, fn author ->
      actor = Profiles.actor_url(viewer)

      to_author(viewer, author, %{
        "@context" => @as,
        "id" => actor <> "#stories/" <> Integer.to_string(story.id) <> "/view",
        "type" => "View",
        "to" => Profiles.actor_url(author),
        "actor" => actor,
        "object" => %{"type" => "Story", "object" => object_id}
      })
    end)
  end

  def viewed(_, _), do: :ok

  @spec interacted(Story.t(), Status.t(), :reaction | :reply) :: :ok
  def interacted(%Story{local: false, remote_url: object_id} = story, %Status{} = status, kind)
      when is_binary(object_id) do
    case Repo.get(Profile, status.profile_id) do
      %Profile{domain: nil} = sender ->
        with_author(story, fn author ->
          to_author(sender, author, %{
            "@context" => @as,
            "id" => status.uri,
            "type" => if(kind == :reply, do: "Story:Reply", else: "Story:Reaction"),
            "to" => Profiles.actor_url(author),
            "actor" => Profiles.actor_url(sender),
            "content" => status.caption,
            "inReplyTo" => object_id,
            "published" => DateTime.to_iso8601(status.inserted_at)
          })
        end)

      _ ->
        :ok
    end
  end

  def interacted(_, _, _), do: :ok

  ## Internals

  defp with_author(%Story{} = story, fun) do
    if Stories.enabled?() do
      case Repo.preload(story, :profile).profile do
        %Profile{} = author -> fun.(author)
        nil -> :ok
      end
    end

    :ok
  end

  defp fan_out(%Profile{domain: nil} = author, activity) do
    for inbox <- OutboundAudience.follower_inboxes(author.id) do
      {:ok, _} = StoryDeliver.enqueue(author.id, inbox, activity, sync: true)
    end

    :ok
  end

  defp fan_out(_, _), do: :ok

  # Upstream sends these to the author's own inbox, not a shared one.
  defp to_author(%Profile{} = from, %Profile{domain: d} = author, activity) when is_binary(d) do
    case author.inbox_url || author.shared_inbox_url do
      inbox when is_binary(inbox) -> {:ok, _} = StoryDeliver.enqueue(from.id, inbox, activity)
      nil -> :ok
    end

    :ok
  end

  defp to_author(_, _, _), do: :ok
end
