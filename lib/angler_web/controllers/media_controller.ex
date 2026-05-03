defmodule AnglerWeb.MediaController do
  @moduledoc """
  Serve media bytes from the local storage backend.

  Public, no auth — equivalent to a CDN. Production deployments should put a
  reverse-proxy / CDN in front of this and let it serve the files directly;
  this controller exists for dev and as the canonical fallback URL Pixelfed
  uses.
  """

  use AnglerWeb, :controller

  alias Angler.Media.Storage.Local

  def serve(conn, %{"path" => parts}) do
    rel = Path.join(parts)
    abs = Path.expand(Path.join(Local.root(), rel))

    cond do
      not String.starts_with?(abs, Path.expand(Local.root())) ->
        send_resp(conn, 403, "")

      not File.exists?(abs) ->
        send_resp(conn, 404, "")

      true ->
        conn
        |> put_resp_content_type(guess_type(abs))
        |> send_file(200, abs)
    end
  end

  defp guess_type(path) do
    case Path.extname(path) do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _ -> "application/octet-stream"
    end
  end
end
