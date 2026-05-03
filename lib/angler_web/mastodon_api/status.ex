defmodule AnglerWeb.MastodonAPI.Status do
  @moduledoc """
  Render an `Angler.Statuses.Status` as a Mastodon `Status` JSON object.

  See `plans/_types/status.md` for the wire shape.

  Per-viewer fields (`favourited`, `reblogged`, `bookmarked`, `muted`,
  `pinned`) are not computed here — overlay them after rendering with
  `apply_viewer_overlay/2` so the base render can be cached without leaking
  one viewer's state to another.
  """

  import Ecto.Query, warn: false

  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.{Mention, Status, StatusHashtag, ViewerOverlay}
  alias AnglerWeb.MastodonAPI.Account

  @doc """
  Render a Status as Mastodon JSON.

  When `viewer_id` is supplied, per-viewer fields (`favourited`, `reblogged`,
  `bookmarked`, …) are computed from the DB and applied. Without it those
  fields are all `false` — appropriate for anonymous reads or for when the
  caller will overlay later in batch.
  """
  @spec render(Status.t(), integer() | nil) :: map()
  def render(%Status{} = status, viewer_id \\ nil) do
    status = Repo.preload(status, [:profile, mentions: :profile, status_hashtags: :hashtag])
    base = render_base(status)

    if viewer_id do
      apply_viewer_overlay(base, ViewerOverlay.for_status(viewer_id, status.id))
    else
      base
    end
  end

  @doc """
  Render a list of statuses, computing the viewer overlay in **one** batched
  query (not one per status).
  """
  @spec render_many([Status.t()], integer() | nil) :: [map()]
  def render_many(statuses, viewer_id \\ nil)
  def render_many([], _), do: []

  def render_many(statuses, nil) do
    Enum.map(statuses, &render(&1, nil))
  end

  def render_many(statuses, viewer_id) when is_integer(viewer_id) do
    overlays = ViewerOverlay.batch(viewer_id, Enum.map(statuses, & &1.id))

    Enum.map(statuses, fn status ->
      base = render(status, nil)
      apply_viewer_overlay(base, Map.get(overlays, status.id, ViewerOverlay.empty()))
    end)
  end

  defp render_base(%Status{} = status) do
    %{
      "id" => Integer.to_string(status.id),
      "created_at" => format_ts(status.inserted_at),
      "in_reply_to_id" => to_id_string(status.in_reply_to_id),
      "in_reply_to_account_id" => to_id_string(status.in_reply_to_profile_id),
      "sensitive" => status.is_nsfw,
      "spoiler_text" => status.cw_summary || "",
      "visibility" => Atom.to_string(status.visibility || :public),
      "language" => status.language || "en",
      "uri" => status.uri || canonical_url(status),
      "url" => status.url || canonical_url(status),
      "replies_count" => status.reply_count,
      "reblogs_count" => status.reblogs_count,
      "favourites_count" => status.likes_count,
      "edited_at" => format_ts(status.edited_at),
      "favourited" => false,
      "reblogged" => false,
      "muted" => false,
      "bookmarked" => false,
      "pinned" => false,
      "content" => status.rendered || "",
      "reblog" => nil,
      "application" => %{"name" => "web", "website" => nil},
      "mentions" => render_mentions(status.mentions),
      "emojis" => [],
      "card" => nil,
      "poll" => nil,
      "media_attachments" => [],
      "account" => Account.render(status.profile),
      "tags" => render_tags(status.status_hashtags)
    }
  end

  @doc """
  Apply per-viewer fields to an already-rendered status.

  `overlay` is a map with optional `:favourited`, `:reblogged`, `:bookmarked`,
  `:pinned`, `:muted` keys. Anything missing stays `false`.
  """
  @spec apply_viewer_overlay(map(), map()) :: map()
  def apply_viewer_overlay(rendered, overlay) when is_map(rendered) and is_map(overlay) do
    Enum.reduce([:favourited, :reblogged, :bookmarked, :pinned, :muted], rendered, fn key, acc ->
      case Map.get(overlay, key) do
        nil -> acc
        v -> Map.put(acc, Atom.to_string(key), v)
      end
    end)
  end

  ## Internals

  defp to_id_string(nil), do: nil
  defp to_id_string(id), do: Integer.to_string(id)

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp canonical_url(%Status{local: true, profile: %Profile{username: username}, id: id}) do
    AnglerWeb.Endpoint.url() <> "/p/" <> username <> "/" <> Integer.to_string(id)
  end

  defp canonical_url(_), do: nil

  defp render_mentions(mentions) when is_list(mentions) do
    Enum.map(mentions, fn %Mention{profile: profile} ->
      %{
        "id" => Integer.to_string(profile.id),
        "username" => profile.username,
        "url" => Profiles.url(profile),
        "acct" => mention_acct(profile)
      }
    end)
  end

  defp render_mentions(_), do: []

  defp mention_acct(%Profile{domain: nil, username: u}), do: u
  defp mention_acct(%Profile{domain: d, username: u}), do: "#{u}@#{d}"

  defp render_tags(status_hashtags) when is_list(status_hashtags) do
    Enum.map(status_hashtags, fn %StatusHashtag{hashtag: %Hashtag{name: name}} ->
      %{
        "name" => name,
        "url" => AnglerWeb.Endpoint.url() <> "/tags/" <> name
      }
    end)
  end

  defp render_tags(_), do: []
end
