defmodule AnglerWeb.GroupsAPI.GroupsSearchController do
  @moduledoc """
  Search variants under `/api/v0/groups/search/...`. The Pixelfed mobile
  UI calls a handful of search shapes — `global` (full-text), `lac`
  (local autocomplete), `addrec` / `getrec` (recents). We implement
  `global` properly and stub the rest.
  """

  use AnglerWeb, :controller

  alias Angler.Groups
  alias Angler.Groups.Group

  ## POST search/global — full-text-ish; we use ILIKE on group name.

  def search_global(conn, params) do
    if Groups.enabled?() do
      q = params["q"] || params["query"] || ""

      body =
        Groups.search(to_string(q))
        |> Enum.map(&render_group_summary/1)

      json(conn, body)
    else
      not_found(conn)
    end
  end

  ## POST search/lac — local-autocomplete; same shape as global for now.

  def search_lac(conn, params), do: search_global(conn, params)

  ## POST search/addrec — record a "recent group". We don't track this
  ## yet; accept and acknowledge.

  def search_addrec(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, %{"code" => 200}), else: not_found(conn))

  ## GET search/getrec — recent groups for the viewer; empty for now.

  def search_getrec(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, []), else: not_found(conn))

  defp render_group_summary(%Group{} = g) do
    %{
      "id" => Integer.to_string(g.id),
      "name" => g.name,
      "slug" => g.slug,
      "description" => g.description,
      "member_count" => g.member_count,
      "avatar" => g.avatar_path || ""
    }
  end

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})
end
