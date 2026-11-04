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

  @content_types %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp",
    ".gif" => "image/gif",
    ".mp4" => "video/mp4",
    ".webm" => "video/webm",
    ".mov" => "video/quicktime"
  }

  ## GET /storage/m/_v2/:pid/:mhash/:uhash/:f
  ##
  ## Legacy Pixelfed media URL format (`storage/m/_v2/...`). Older clients
  ## and some federated links still use it. We resolve to the standard
  ## `/storage/...` path via the existing serve/1 action; if no file is
  ## present, redirect to a placeholder so the response shape matches
  ## upstream (browsers see an image, not a 404).
  def fallback_redirect(conn, %{"pid" => pid, "mhash" => mhash, "uhash" => uhash, "f" => f}) do
    rel = Path.join(["m", "_v2", pid, mhash, uhash, f])
    abs = Path.expand(Path.join(Local.root(), rel))
    safe? = String.starts_with?(abs, Path.expand(Local.root()))

    cond do
      not safe? -> send_resp(conn, 403, "")
      File.exists?(abs) -> Phoenix.Controller.redirect(conn, to: "/storage/" <> rel)
      true -> Phoenix.Controller.redirect(conn, to: "/storage/no-preview.png")
    end
  end

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

  defp guess_type(path),
    do: Map.get(@content_types, Path.extname(path), "application/octet-stream")
end
