defmodule Angler.Stories.Federation do
  @moduledoc """
  Inbound federated stories, as upstream HandlesStories and the Story
  branch of HandlesDeletes:

    * `Add` of a `Story` — a followed remote account posted one. The object
      is only a bearcap (`bear:?t=<token>&u=<url>`); `Workers.StoryFetch`
      fetches it with the token and mirrors it as a remote story. Its media
      is hotlinked, like remote post media.
    * `View` of a `Story` — a remote follower saw one of ours.
    * `Story:Reaction` / `Story:Reply` — a remote follower reacted to or
      answered one of ours. It becomes a `:direct` status from them to the
      author, filed into their DM conversation.
    * `Delete` of a `Story` — the owner took a mirrored one down.

  `actor_url` is always the signature-verified sender, and every handler
  only lets it act as itself: on its own stories, or as the viewer, reactor
  or replier. Anything that doesn't check out is dropped silently.
  """

  import Ecto.Query, warn: false

  alias Angler.Conversations
  alias Angler.Federation.Actor
  alias Angler.Follows
  alias Angler.Follows.Follower
  alias Angler.Profiles
  alias Angler.Profiles.{BlocksMutes, DomainBlocks, Profile}
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.{Mention, Status}
  alias Angler.Stories
  alias Angler.Stories.Story
  alias Angler.Stories.Workers.StoryFetch

  @max_text 500

  ## Add

  @spec handle_add(map(), String.t()) :: :ok
  def handle_add(%{"id" => id, "object" => %{"type" => "Story"} = object} = activity, actor_url)
      when is_binary(id) do
    with true <- Stories.enabled?(),
         true <- Actor.same_actor?(activity["actor"], actor_url),
         true <- Actor.same_host?(id, actor_url),
         {:ok, %{url: url, token: token}} <- decode_bearcap(object["object"]),
         true <- Actor.same_host?(url, actor_url) do
      {:ok, _} = StoryFetch.enqueue(url, token, actor_url)
      :ok
    else
      _ -> :ok
    end
  end

  def handle_add(_, _), do: :ok

  @doc "Split a bearcap URI into its URL and token (upstream Util\\Lexer\\Bearcap)."
  @spec decode_bearcap(term()) :: {:ok, %{url: String.t(), token: String.t()}} | :error
  def decode_bearcap("bear:?" <> query) do
    params =
      for part <- String.split(query, "&"), into: %{} do
        case part do
          "t=" <> token -> {:token, token}
          "u=" <> url -> {:url, url}
          other -> {other, nil}
        end
      end

    case params do
      %{token: token, url: url} when byte_size(token) >= 10 ->
        if http_url(url), do: {:ok, %{url: url, token: token}}, else: :error

      _ ->
        :error
    end
  end

  def decode_bearcap(_), do: :error

  @doc """
  Mirror a fetched `Story` document from `actor_url`, if someone here
  follows them. Dedupes on the story id. Returns `{:ok, story}`, `:exists`
  or `:skip`.
  """
  @spec ingest(map(), String.t(), String.t()) :: {:ok, Story.t()} | :exists | :skip
  def ingest(doc, url, actor_url) do
    with {:ok, %Profile{domain: d, status: nil} = author} when is_binary(d) <-
           Actor.resolve(actor_url),
         true <- local_followers?(author.id),
         {:ok, attrs} <- parse_story(doc, url, actor_url) do
      %Story{id: Angler.Snowflake.next(), profile_id: author.id, local: false, active: true}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert!(
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, "(remote_url) WHERE remote_url IS NOT NULL"}
      )
      |> then(fn story ->
        # On a conflict nothing was written and the id we chose is unused.
        if Repo.exists?(from s in Story, where: s.id == ^story.id),
          do: {:ok, story},
          else: :exists
      end)
    else
      _ -> :skip
    end
  end

  @doc "Whether the story at `url` is already mirrored."
  @spec mirrored?(String.t()) :: boolean()
  def mirrored?(url), do: Repo.exists?(from s in Story, where: s.remote_url == ^url)

  defp local_followers?(profile_id) do
    Repo.exists?(
      from f in Follower,
        join: p in Profile,
        on: p.id == f.following_id,
        where: f.profile_id == ^profile_id and not is_nil(f.accepted_at) and is_nil(p.domain)
    )
  end

  @image_mimes ~w(image/jpeg image/png image/gif image/webp image/avif)
  @video_mimes ~w(video/mp4 video/webm)

  # Upstream StoryValidator plus StoryFetch's payload checks. The document
  # must be the story the bearcap named, by the actor who sent the Add.
  defp parse_story(%{"type" => "Story", "id" => id} = doc, url, actor_url) when is_binary(id) do
    now = DateTime.utc_now()

    with true <- Actor.same_actor?(id, url),
         true <- Actor.same_actor?(ref(doc["attributedTo"]), actor_url),
         %{"url" => media_url, "mediaType" => mime} = att when is_binary(media_url) <-
           ld_node(doc["attachment"]),
         {:ok, type} <- media_type(att["type"], mime),
         true <- is_binary(http_url(media_url)),
         duration when is_integer(duration) and duration in 1..300 <- doc["duration"],
         {:ok, published, _} <- DateTime.from_iso8601(to_string(doc["published"])),
         {:ok, expires, _} <- DateTime.from_iso8601(to_string(doc["expiresAt"])),
         true <- DateTime.compare(expires, published) == :gt,
         true <- DateTime.compare(expires, now) == :gt do
      {:ok,
       %{
         remote_url: url,
         type: type,
         mime: mime,
         path: media_url,
         duration_ms: duration * 1_000,
         can_reply: doc["can_reply"] == true,
         can_react: doc["can_react"] == true,
         inserted_at: Enum.min([published, now], DateTime),
         expires_at: Enum.min([expires, DateTime.add(now, 24 * 60 * 60, :second)], DateTime)
       }}
    else
      _ -> :error
    end
  end

  defp parse_story(_, _, _), do: :error

  defp media_type("Image", mime) when mime in @image_mimes, do: {:ok, "photo"}
  defp media_type("Video", mime) when mime in @video_mimes, do: {:ok, "video"}
  defp media_type(_, _), do: :error

  ## View

  @spec handle_view(map(), String.t()) :: :ok
  def handle_view(
        %{"object" => %{"type" => "Story", "object" => story_url}} = activity,
        actor_url
      ) do
    with true <- Actor.same_actor?(activity["actor"], actor_url),
         %Story{} = story <- local_story(story_url),
         {:ok, %Profile{domain: d} = viewer} when is_binary(d) <- Actor.resolve(actor_url),
         false <- shut_out?(story.profile_id, viewer) do
      # Only an active story, from a follower (`Stories.mark_seen/2`).
      _ = Stories.mark_seen(viewer, story.id)
      :ok
    else
      _ -> :ok
    end
  end

  def handle_view(_, _), do: :ok

  ## Story:Reaction / Story:Reply

  @spec handle_interaction(map(), String.t(), :reaction | :reply) :: :ok
  def handle_interaction(%{"id" => id, "inReplyTo" => story_url} = activity, actor_url, kind)
      when is_binary(id) and byte_size(id) <= 1_000 do
    uri = String.replace_suffix(id, "/activity", "")

    with true <- Actor.same_actor?(activity["actor"], actor_url),
         true <- Actor.same_host?(id, actor_url),
         text when is_binary(text) <- clean_text(activity["content"]),
         false <- Repo.exists?(from s in Status, where: s.uri == ^uri),
         %Story{} = story <- local_story(story_url),
         true <- open_to?(story, kind),
         true <- Actor.same_actor?(url_field(activity["to"]), Profiles.actor_url(story.profile)),
         {:ok, %Profile{domain: d, status: nil} = sender} when is_binary(d) <-
           Actor.resolve(actor_url),
         false <- shut_out?(story.profile_id, sender),
         true <- follows?(sender.id, story.profile_id) do
      store_message(story, sender, kind, text, uri)
    else
      _ -> :ok
    end
  end

  def handle_interaction(_, _, _), do: :ok

  defp open_to?(%Story{active: true} = story, kind) do
    live? = DateTime.compare(story.expires_at, DateTime.utc_now()) == :gt
    live? and if(kind == :reply, do: story.can_reply, else: story.can_react)
  end

  defp open_to?(_, _), do: false

  defp store_message(%Story{} = story, %Profile{} = sender, kind, text, uri) do
    attrs = %{
      profile_id: sender.id,
      caption: text,
      rendered: "",
      visibility: :direct,
      scope: "direct",
      type: if(kind == :reply, do: "story:reply", else: "story:reaction"),
      local: false,
      uri: uri,
      url: uri,
      in_reply_to_profile_id: story.profile_id,
      story_id: story.id
    }

    with {:ok, %Status{} = status} <- Statuses.create_remote(attrs) do
      %{status_id: status.id, profile_id: story.profile_id}
      |> Mention.changeset()
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:status_id, :profile_id])

      Conversations.record_story_message(status)
    else
      _ -> :ok
    end
  end

  ## Delete

  @doc "Delete of a mirrored story: only its owner may take it down."
  @spec handle_delete(String.t(), String.t()) :: :ok
  def handle_delete(story_url, actor_url) when is_binary(story_url) and is_binary(actor_url) do
    case Repo.one(
           from s in Story,
             join: p in assoc(s, :profile),
             where: s.remote_url == ^story_url and s.local == false,
             preload: [profile: p]
         ) do
      %Story{profile: %Profile{remote_url: owner}} = story ->
        if Actor.same_actor?(owner, actor_url), do: Repo.delete!(story)
        :ok

      nil ->
        :ok
    end
  end

  def handle_delete(_, _), do: :ok

  ## Internals

  # One of our stories by its object URL, `/stories/:username/:id`.
  defp local_story(url) do
    base = AnglerWeb.Endpoint.url() <> "/stories/"

    with url when is_binary(url) <- url_field(url),
         true <- String.starts_with?(url, base),
         [username, id] <- url |> String.replace_prefix(base, "") |> String.split("/"),
         {id, ""} <- Integer.parse(id),
         %Story{local: true} = story <-
           Repo.one(from s in Story, where: s.id == ^id, preload: :profile),
         %Profile{domain: nil, username: ^username, status: nil} <- story.profile do
      story
    else
      _ -> nil
    end
  end

  # The author blocks the remote account, or its whole domain.
  defp shut_out?(author_id, %Profile{id: id, domain: domain}),
    do: BlocksMutes.blocked?(author_id, id) or DomainBlocks.blocked?(author_id, domain)

  defp follows?(follower_id, followee_id),
    do: match?(%{accepted_at: %DateTime{}}, Follows.get_follower(followee_id, follower_id))

  defp clean_text(html) when is_binary(html) do
    text =
      html
      |> String.replace(~r/<[^>]*>/, "")
      |> String.replace("&nbsp;", " ")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&amp;", "&")
      |> String.trim()

    if text == "", do: nil, else: String.slice(text, 0, @max_text)
  end

  defp clean_text(_), do: nil

  defp ref([first | _]), do: ref(first)
  defp ref(%{"id" => id}), do: ref(id)
  defp ref(id) when is_binary(id), do: id
  defp ref(_), do: nil

  defp ld_node([first | _]), do: ld_node(first)
  defp ld_node(%{} = node), do: node
  defp ld_node(_), do: nil

  defp url_field(value) do
    case ref(value) do
      id when is_binary(id) -> http_url(id)
      _ -> nil
    end
  end

  defp http_url(s) when is_binary(s) do
    case URI.parse(s) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> s
      _ -> nil
    end
  end

  defp http_url(_), do: nil
end
