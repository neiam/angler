defmodule AnglerWeb.SearchController do
  @moduledoc """
  Lightweight, unauthenticated type-ahead used by the navbar search box
  (`Layouts.app`'s colocated `.SearchBox` hook).

  Returns a small set of accounts and hashtags as JSON. Only public data is
  exposed (discoverable accounts and public hashtags), so no auth is required —
  the full, viewer-scoped search lives behind `AnglerWeb.SearchLive` at
  `/search`.
  """

  use AnglerWeb, :controller

  alias Angler.Hashtags
  alias Angler.Profiles
  alias Angler.Search

  @limit 6

  def suggest(conn, params) do
    q = String.trim(params["q"] || "")

    if q == "" do
      json(conn, %{"accounts" => [], "hashtags" => []})
    else
      counts = Hashtags.usage_counts()

      json(conn, %{
        "accounts" => Enum.map(Search.accounts(q, limit: @limit), &account_json/1),
        "hashtags" => Enum.map(Search.hashtags(q, limit: @limit), &hashtag_json(&1, counts))
      })
    end
  end

  defp account_json(p) do
    %{
      "acct" => acct(p),
      "display_name" => (p.name && p.name != "" && p.name) || p.username,
      "avatar" => p.avatar_path,
      "url" => account_url(p),
      "followers_count" => p.followers_count
    }
  end

  defp hashtag_json(h, counts) do
    %{
      "name" => h.name,
      "count" => Map.get(counts, h.name, 0),
      "url" => ~p"/tags/#{h.name}"
    }
  end

  defp acct(%{domain: domain, username: u}) when is_binary(domain) and domain != "",
    do: "#{u}@#{domain}"

  defp acct(%{username: u}), do: u

  # Local accounts resolve to the in-app profile route; remote ones link out to
  # their origin so we don't promise a local page we can't fully render.
  defp account_url(%{domain: domain} = p) when is_binary(domain) and domain != "",
    do: Profiles.url(p)

  defp account_url(%{username: u}), do: ~p"/@#{u}"
end
