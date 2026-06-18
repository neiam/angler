defmodule AnglerWeb.ExportController do
  @moduledoc """
  Serves the account-data archive built by `Angler.Export.Workers.AccountArchive`
  to its owner. Session-authenticated (the `:browser_session` pipeline assigns
  `current_user`); the file is read only from the requesting user's own export
  directory, so there is no path for one user to fetch another's archive.
  """

  use AnglerWeb, :controller

  alias Angler.Export.AccountArchive
  alias Angler.Export.PostExport
  alias Angler.Profiles

  @doc "Stream the user's posts as an ActivityPub/JSON file (no media bundle)."
  def posts_json(conn, _params) do
    case conn.assigns[:current_user] do
      %{profile_id: profile_id} when is_integer(profile_id) ->
        profile = Profiles.get_profile(profile_id)
        body = Jason.encode!(PostExport.notes_for(profile), pretty: true)

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="angler-posts-#{profile.username}.json")
        )
        |> send_resp(200, body)

      _ ->
        redirect(conn, to: ~p"/login?next=/settings/data")
    end
  end

  def download(conn, _params) do
    case conn.assigns[:current_user] do
      %{profile_id: profile_id} when is_integer(profile_id) ->
        dir = AccountArchive.default_dir(profile_id)

        case latest_zip(dir) do
          nil ->
            conn
            |> put_flash(:error, "No export is ready yet. Generate one first.")
            |> redirect(to: ~p"/settings/data")

          path ->
            send_download(conn, {:file, path}, filename: Path.basename(path))
        end

      _ ->
        redirect(conn, to: ~p"/login?next=/settings/data")
    end
  end

  # Newest .zip in the user's export dir (there is normally just one).
  defp latest_zip(dir) do
    case File.dir?(dir) && Path.wildcard(Path.join(dir, "*.zip")) do
      files when is_list(files) and files != [] ->
        files
        |> Enum.max_by(fn f -> File.stat!(f).mtime end)

      _ ->
        nil
    end
  end
end
