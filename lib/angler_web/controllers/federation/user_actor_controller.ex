defmodule AnglerWeb.Federation.UserActorController do
  @moduledoc """
  GET /users/:username — the AP `Person` actor doc for a local profile.

  Federating peers fetch this to get our public key and inbox URL. We always
  return JSON regardless of `Accept` header for now (the HTML profile page is
  a separate route — out of scope for the federation slice).
  """

  use AnglerWeb, :controller

  alias Angler.Federation.ActorBuilder
  alias Angler.Profiles
  alias Angler.Profiles.Profile

  def show(conn, %{"username" => username}) do
    case Profiles.get_local_by_username(username) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "Not Found"})

      %Profile{} = profile ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode_to_iodata!(ActorBuilder.person(profile)))
    end
  end
end
