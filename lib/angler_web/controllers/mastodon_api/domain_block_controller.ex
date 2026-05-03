defmodule AnglerWeb.MastodonAPI.DomainBlockController do
  @moduledoc """
    * GET    /api/v1/domain_blocks  — list blocked domains for viewer
    * POST   /api/v1/domain_blocks  — block `domain=`
    * DELETE /api/v1/domain_blocks  — unblock `domain=`
  """

  use AnglerWeb, :controller

  alias Angler.Profiles.DomainBlocks
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, DomainBlocks.list(profile.id))
  end

  def create(conn, %{"domain" => domain}) when is_binary(domain) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    :ok = DomainBlocks.block(profile, domain)
    json(conn, %{})
  end

  def create(conn, _), do: conn |> put_status(:bad_request) |> json(%{"error" => "domain required"})

  def delete(conn, %{"domain" => domain}) when is_binary(domain) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    :ok = DomainBlocks.unblock(profile, domain)
    json(conn, %{})
  end

  def delete(conn, _), do: conn |> put_status(:bad_request) |> json(%{"error" => "domain required"})
end
