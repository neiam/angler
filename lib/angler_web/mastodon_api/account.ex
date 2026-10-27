defmodule AnglerWeb.MastodonAPI.Account do
  @moduledoc """
  Render an `Angler.Profiles.Profile` as a Mastodon `Account` JSON object.

  See `plans/_types/account.md` for the wire shape.

  When `pe: true` is passed (Pixelfed mobile passes `?_pe=1`), the renderer
  adds the Pixelfed-extension fields the mobile app's `LoginUserResponse`
  type expects: `is_admin`, `local`, `location`, `website`, `pronouns`,
  `note_text`, `header_bg`, `last_fetched_at`, plus a `settings` block.
  Pass `user: %User{}` to surface `is_admin` correctly.
  """

  alias Angler.Accounts.User
  alias Angler.Profiles
  alias Angler.Profiles.Profile

  @default_avatar ""
  @default_header ""

  @spec render(Profile.t(), keyword()) :: map()
  def render(%Profile{} = p, opts \\ []) do
    base = %{
      "id" => Integer.to_string(p.id),
      "username" => p.username,
      "acct" => acct(p),
      "display_name" => p.name || "",
      "locked" => p.is_private,
      "bot" => p.is_bot,
      "discoverable" => p.discoverable,
      "group" => false,
      "created_at" => format_ts(p.inserted_at),
      "note" => p.bio || "",
      "url" => Profiles.url(p),
      "avatar" => p.avatar_path || @default_avatar,
      "avatar_static" => p.avatar_path || @default_avatar,
      "header" => p.header_path || @default_header,
      "header_static" => p.header_path || @default_header,
      "followers_count" => p.followers_count,
      "following_count" => p.following_count,
      "statuses_count" => p.statuses_count,
      "last_status_at" => format_ts(p.last_status_at),
      "emojis" => [],
      "moved" => moved(p),
      "fields" => []
    }

    if Keyword.get(opts, :pe, false) do
      Map.merge(base, pe_fields(p, opts))
    else
      base
    end
  end

  @spec render_many([Profile.t()], keyword()) :: [map()]
  def render_many(profiles, opts \\ []), do: Enum.map(profiles, &render(&1, opts))

  ## Helpers

  # Local profile: bare username. Remote: `username@domain` (Mastodon uses the
  # full handle here even though Pixelfed v1 sometimes returns bare; we follow
  # Mastodon since most clients depend on it).
  defp acct(%Profile{domain: nil, username: u}), do: u
  defp acct(%Profile{domain: d, username: u}), do: "#{u}@#{d}"

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp pe_fields(%Profile{} = p, opts) do
    %{
      "is_admin" => is_admin?(opts),
      "local" => is_nil(p.domain),
      # Pixelfed-rn types these as `string`; send "" rather than null so the
      # app's `LoginUserResponse` never sees a null where it expects a string.
      "location" => p.location || "",
      "website" => p.website || "",
      "pronouns" => p.pronouns || [],
      "note_text" => p.bio_text || strip_tags(p.bio || ""),
      "header_bg" => p.header_path || @default_header,
      "last_fetched_at" => format_ts(p.last_fetched_at),
      # Drives the story ring in the Pixelfed app (upstream bbd7618c4). Only
      # local stories exist here, so remote accounts never have one.
      "has_story" => is_nil(p.domain) and Angler.Stories.has_active?(p.id),
      "settings" => settings(p, opts)
    }
  end

  # The account this one moved to, in the short shape upstream renders
  # (94b8fea32). Only fetched when set, which is rare.
  defp moved(%Profile{moved_to_id: nil}), do: nil

  defp moved(%Profile{moved_to_id: id}) do
    case Profiles.get_profile(id) do
      %Profile{} = target ->
        %{
          "id" => Integer.to_string(target.id),
          "acct" => acct(target),
          "avatar" => target.avatar_path || @default_avatar
        }

      nil ->
        nil
    end
  end

  defp is_admin?(opts) do
    case Keyword.get(opts, :user) do
      %User{is_admin: true} -> true
      _ -> false
    end
  end

  # The stored account settings are passed in via `opts[:settings]` for self
  # renders (verify_credentials / update_credentials). For other accounts no
  # settings are loaded (no N+1), so defaults apply. `indexable` and
  # `is_suggestable` always come from profile columns.
  defp settings(%Profile{} = p, opts) do
    s = Keyword.get(opts, :settings, %{})

    %{
      "crawlable" => sget(s, "crawlable", true),
      "disable_embeds" => sget(s, "disable_embeds", false),
      "high_contrast_mode" => sget(s, "high_contrast_mode", false),
      "indexable" => p.indexable_search,
      "is_suggestable" => p.discoverable,
      "media_descriptions" => sget(s, "media_descriptions", false),
      "public_dm" => sget(s, "public_dm", false),
      "reduce_motion" => sget(s, "reduce_motion", false),
      "show_atom" => sget(s, "show_atom", false),
      "show_profile_follower_count" => sget(s, "show_profile_follower_count", true),
      "show_profile_following_count" => sget(s, "show_profile_following_count", true),
      "video_autoplay" => sget(s, "video_autoplay", true),
      # Compose defaults the app pre-selects (upstream 59f57b110).
      "default_scope" => sget(s, "default_scope", "public"),
      "default_license" => license_id(sget(s, "default_license", 1))
    }
  end

  defp license_id(n) when is_integer(n), do: n

  defp license_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> 1
    end
  end

  defp license_id(_), do: 1

  defp sget(s, key, default) when is_map(s), do: Map.get(s, key, default)
  defp sget(_, _, default), do: default

  defp strip_tags(s) when is_binary(s),
    do: s |> String.replace(~r/<[^>]*>/, "") |> String.trim()
end
