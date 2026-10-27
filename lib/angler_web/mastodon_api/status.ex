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

  alias Angler.Filters.Matching
  alias Angler.Hashtags.Hashtag
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Media.Asset
  alias Angler.Polls
  alias Angler.Reblogs.Reblog
  alias Angler.Statuses.{Mention, Status, StatusHashtag, ViewerOverlay}
  alias AnglerWeb.MastodonAPI.{Account, Media}
  alias AnglerWeb.MastodonAPI.Poll, as: PollJSON

  @doc """
  Render a Status as Mastodon JSON.

  When `viewer_id` is supplied, per-viewer fields (`favourited`, `reblogged`,
  `bookmarked`, …) are computed from the DB and applied. Without it those
  fields are all `false` — appropriate for anonymous reads or for when the
  caller will overlay later in batch.
  """
  @spec render(Status.t() | Reblog.t(), integer() | nil, keyword()) :: map()
  def render(status, viewer_id \\ nil, opts \\ [])

  def render(%Reblog{status: %Status{} = status} = reblog, viewer_id, opts) do
    wrap(reblog, render(status, viewer_id, opts), opts)
  end

  def render(%Status{} = status, viewer_id, opts) do
    status =
      Repo.preload(status,
        profile: [],
        mentions: :profile,
        status_hashtags: :hashtag,
        media_attachments: []
      )

    base = render_base(status)

    if viewer_id do
      base
      |> apply_viewer_overlay(ViewerOverlay.for_status(viewer_id, status.id))
      # Single render (e.g. the permalink page) never drops the requested post;
      # it only stamps the marker so the UI can gate it.
      |> apply_filtered(Matching.action_for(viewer_id, status, opts[:context]))
    else
      base
    end
  end

  @doc """
  Render a list of statuses, computing the viewer overlay in **one** batched
  query (not one per status).
  """
  @spec render_many([Status.t()], integer() | nil, keyword()) :: [map()]
  def render_many(statuses, viewer_id \\ nil, opts \\ [])
  def render_many([], _, _), do: []

  def render_many(statuses, nil, opts) do
    Enum.map(statuses, &render(&1, nil, opts))
  end

  # Items are statuses or boosts (`%Reblog{}` with `status` loaded); a
  # boost is judged by — and overlaid from — the post it boosts.
  def render_many(items, viewer_id, opts) when is_integer(viewer_id) do
    statuses = Enum.map(items, &boosted/1)
    overlays = ViewerOverlay.batch(viewer_id, Enum.map(statuses, & &1.id))
    actions = Matching.actions_for(viewer_id, statuses, opts[:context])

    items
    # `hide`-action matches are removed from the list entirely; `warn`/`blur`
    # stay but get a `filtered` marker the client/UI gates on.
    |> Enum.reject(fn item ->
      match = Map.get(actions, boosted(item).id)
      match && match.action == "hide"
    end)
    |> Enum.map(fn item ->
      status = boosted(item)

      rendered =
        status
        |> render(nil)
        |> apply_viewer_overlay(Map.get(overlays, status.id, ViewerOverlay.empty()))
        |> apply_filtered(Map.get(actions, status.id))

      case item do
        %Reblog{} = reblog -> wrap(reblog, rendered, opts)
        _ -> rendered
      end
    end)
  end

  defp boosted(%Reblog{status: %Status{} = s}), do: s
  defp boosted(%Status{} = s), do: s

  @doc """
  A boost as a Mastodon wrapper status: the booster's, carrying the post in
  `reblog`. Its id is the boost's own (`reblogs.reblog_status_id`). The
  Pixelfed app (`pe: true`) gets upstream's flattened form instead: the post
  itself, with `reblogged_by` naming the booster (bfbc54989).
  """
  @spec wrap(Reblog.t(), map(), keyword()) :: map()
  def wrap(%Reblog{} = reblog, rendered, opts \\ []) do
    reblog = Repo.preload(reblog, :profile)
    booster = Account.render(reblog.profile)

    if Keyword.get(opts, :pe, false) do
      Map.put(rendered, "reblogged_by", booster)
    else
      %{
        "id" => Integer.to_string(reblog.reblog_status_id),
        "created_at" => format_ts(reblog.inserted_at),
        "in_reply_to_id" => nil,
        "in_reply_to_account_id" => nil,
        "sensitive" => false,
        "spoiler_text" => "",
        "visibility" => rendered["visibility"],
        "language" => nil,
        "uri" => reblog.remote_url || rendered["uri"],
        "url" => rendered["url"],
        "replies_count" => 0,
        "reblogs_count" => 0,
        "favourites_count" => 0,
        "edited_at" => nil,
        "favourited" => rendered["favourited"],
        "reblogged" => rendered["reblogged"],
        "muted" => rendered["muted"],
        "bookmarked" => rendered["bookmarked"],
        "pinned" => false,
        "content" => "",
        "pf_type" => "share",
        "content_text" => "",
        "reblog" => rendered,
        "application" => nil,
        "mentions" => [],
        "emojis" => [],
        "card" => nil,
        "poll" => nil,
        "media_attachments" => [],
        "account" => booster,
        "tags" => [],
        "filtered" => rendered["filtered"]
      }
    end
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
      # Pixelfed extensions the mobile app depends on: `pf_type` drives the
      # photo/video grid filters (profile grid, explore, feed) and `content_text`
      # is the plain-text caption used for client-side checks. Missing `pf_type`
      # makes the app's `['photo','photo:album','video'].includes(pf_type)` and
      # `pf_type === 'photo'` filters drop every post.
      "pf_type" => status.pf_type || status.type || "text",
      "content_text" => status.caption || "",
      "reblog" => nil,
      "application" => %{"name" => "web", "website" => nil},
      "mentions" => render_mentions(status.mentions),
      "emojis" => [],
      "card" => nil,
      "poll" => render_poll(status),
      "media_attachments" => render_media(status),
      "account" => Account.render(status.profile),
      "tags" => render_tags(status.status_hashtags),
      "filtered" => []
    }
  end

  # Stamp the Mastodon `filtered` array from a matcher result. `nil` (no match)
  # leaves the default empty list in place.
  defp apply_filtered(rendered, nil), do: rendered

  defp apply_filtered(rendered, %{action: action, title: title}) do
    Map.put(rendered, "filtered", [
      %{
        "filter" => %{
          "id" => "0",
          "title" => title,
          "filter_action" => action,
          "context" => []
        },
        "keyword_matches" => [],
        "status_matches" => []
      }
    ])
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

  defp render_media(%Status{media_attachments: %Ecto.Association.NotLoaded{}}), do: []
  defp render_media(%Status{media_attachments: nil}), do: []

  defp render_media(%Status{media_attachments: assets}) when is_list(assets) do
    Enum.map(assets, fn %Asset{} = a -> Media.render(a) end)
  end

  defp render_poll(%Status{id: status_id}) do
    case Polls.get_for_status(status_id) do
      nil -> nil
      poll -> PollJSON.render(poll)
    end
  end
end
