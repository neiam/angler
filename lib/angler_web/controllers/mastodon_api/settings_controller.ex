defmodule AnglerWeb.MastodonAPI.SettingsController do
  @moduledoc """
    * GET  /api/v1.1/web/settings        — UI toggles map (returns [] when empty)
    * POST /api/v1.1/web/settings        — set one whitelisted field
    * GET  /api/v1.1/app/settings        — mobile app `common` blob
    * POST /api/v1.1/app/settings        — replace `common`
    * GET  /api/v1.1/compose/settings    — server-side defaults for the composer
  """

  use AnglerWeb, :controller

  alias Angler.Accounts.Settings
  alias AnglerWeb.Plugs.BearerAuth

  ## web/settings

  def get_web(conn, _params) do
    %{user: user} = BearerAuth.current_scope(conn)
    row = Settings.get(user.id)

    case row.web do
      m when is_map(m) and map_size(m) == 0 -> json(conn, [])
      m -> json(conn, m)
    end
  end

  def set_web(conn, %{"field" => field, "value" => value}) do
    %{user: user} = BearerAuth.current_scope(conn)

    case Settings.set_web_field(user.id, field, value) do
      {:ok, _} ->
        json(conn, [200])

      {:error, :unknown_field} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          "error" => "Validation failed",
          "errors" => %{
            "field" => [
              "must be one of: " <> Enum.join(Settings.web_allowed_fields(), ", ")
            ]
          }
        })
    end
  end

  def set_web(conn, _) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "Validation failed", "errors" => %{"field" => ["is required"]}})
  end

  ## app/settings

  def get_app(conn, _params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)
    row = Settings.get(user.id)

    json(conn, %{
      "id" => Integer.to_string(profile.id),
      "username" => profile.username,
      "updated_at" =>
        case row.updated_at do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end,
      "common" => row.app || %{}
    })
  end

  def set_app(conn, params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)
    common = params["common"] || %{}

    {:ok, row} = Settings.set_app(user.id, common)

    json(conn, %{
      "id" => Integer.to_string(profile.id),
      "username" => profile.username,
      "updated_at" => DateTime.to_iso8601(row.updated_at),
      "common" => row.app
    })
  end

  ## compose/settings

  def compose(conn, _params) do
    %{profile: profile, user: user} = BearerAuth.current_scope(conn)

    json(conn, %{
      "allowed_media_types" => ~w(
        image/jpeg image/png image/webp image/gif
        video/mp4 video/webm video/quicktime
      ),
      "max_caption_length" => 5000,
      "default_license" => 1,
      "media_descriptions" => false,
      "max_file_size" => 100 * 1024,
      "max_media_attachments" => 10,
      "max_altext_length" => 1500,
      "default_scope" => if(profile.is_private, do: "private", else: "public"),
      "default_language" => Map.get(user, :language) || "en"
    })
  end
end
