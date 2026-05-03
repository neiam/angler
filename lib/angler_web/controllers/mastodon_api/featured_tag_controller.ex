defmodule AnglerWeb.MastodonAPI.FeaturedTagController do
  @moduledoc """
    * GET    /api/v1/featured_tags        — own featured tags
    * POST   /api/v1/featured_tags        — feature `name=`
    * DELETE /api/v1/featured_tags/:id    — unfeature
    * GET    /api/v1/accounts/:id/featured_tags — public listing for any profile
  """

  use AnglerWeb, :controller

  alias Angler.Profiles.FeaturedTags
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, Enum.map(FeaturedTags.list(profile.id), &render_one/1))
  end

  def for_account(conn, %{"id" => id}) do
    case parse_id(id) do
      {:ok, n} -> json(conn, Enum.map(FeaturedTags.list(n), &render_one/1))
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def create(conn, %{"name" => name}) when is_binary(name) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    {:ok, tag} = FeaturedTags.feature(profile, name)
    json(conn, render_one(tag))
  end

  def create(conn, _), do: conn |> put_status(:bad_request) |> json(%{"error" => "name required"})

  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    case parse_id(id) do
      {:ok, n} ->
        :ok = FeaturedTags.unfeature(profile, n)
        json(conn, %{})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  defp render_one(tag) do
    %{
      "id" => Integer.to_string(tag.id),
      "name" => tag.name,
      "url" => AnglerWeb.Endpoint.url() <> "/tags/" <> tag.name,
      "statuses_count" => 0,
      "last_status_at" => nil
    }
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error
end
