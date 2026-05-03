defmodule AnglerWeb.MastodonAPI.PreferencesController do
  @moduledoc "GET /api/v1/preferences — derived defaults for the authed user."

  use AnglerWeb, :controller

  alias AnglerWeb.Plugs.BearerAuth

  def show(conn, _params) do
    %{profile: profile, user: user} = BearerAuth.current_scope(conn)

    json(conn, %{
      "posting:default:visibility" => if(profile.is_private, do: "private", else: "public"),
      "posting:default:sensitive" => false,
      "posting:default:language" => Map.get(user, :language) || "en",
      "reading:expand:media" => "default",
      "reading:expand:spoilers" => false
    })
  end
end
