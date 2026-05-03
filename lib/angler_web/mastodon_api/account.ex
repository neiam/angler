defmodule AnglerWeb.MastodonAPI.Account do
  @moduledoc """
  Render an `Angler.Profiles.Profile` as a Mastodon `Account` JSON object.

  See `plans/_types/account.md` for the wire shape.
  """

  alias Angler.Profiles
  alias Angler.Profiles.Profile

  @default_avatar ""
  @default_header ""

  @spec render(Profile.t()) :: map()
  def render(%Profile{} = p) do
    %{
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
      "moved" => nil,
      "fields" => []
    }
  end

  @spec render_many([Profile.t()]) :: [map()]
  def render_many(profiles), do: Enum.map(profiles, &render/1)

  ## Helpers

  # Local profile: bare username. Remote: `username@domain` (Mastodon uses the
  # full handle here even though Pixelfed v1 sometimes returns bare; we follow
  # Mastodon since most clients depend on it).
  defp acct(%Profile{domain: nil, username: u}), do: u
  defp acct(%Profile{domain: d, username: u}), do: "#{u}@#{d}"

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
