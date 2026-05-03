defmodule AnglerWeb.Federation.WebfingerController do
  @moduledoc """
  GET /.well-known/webfinger.

  See `plans/federation/endpoints/get_well_known_webfinger.md`.
  """

  use AnglerWeb, :controller

  alias Angler.Federation.Webfinger
  alias Angler.Profiles

  def show(conn, params) do
    our_domain = URI.parse(AnglerWeb.Endpoint.url()).host

    case Webfinger.parse_resource(params["resource"], our_domain) do
      {:instance_actor, _domain} ->
        respond(conn, Webfinger.instance_actor_jrd(our_domain))

      {:local, username} ->
        case Profiles.get_local_by_username(username) do
          nil -> bad(conn)
          profile -> respond(conn, Webfinger.profile_jrd(profile, our_domain))
        end

      :invalid ->
        bad(conn)
    end
  end

  defp respond(conn, jrd) do
    conn
    |> put_resp_content_type("application/jrd+json")
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(200, Jason.encode_to_iodata!(jrd))
  end

  defp bad(conn), do: send_resp(conn, 400, "")
end
