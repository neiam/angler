defmodule AnglerWeb.Federation.BlockSyncController do
  @moduledoc """
  GET /f/block_sync — FEP-070c: our users' blocks of actors on the server
  that signed the request, and nobody else's, as upstream
  FederationController::blockSynchronization. The digest doubles as the
  ETag, so an unchanged list is a 304. 404 when we don't disclose, 401
  unsigned, 403 for a peer we don't disclose to.
  """

  use AnglerWeb, :controller

  alias Angler.Federation.{BlockSync, Sync}
  alias AnglerWeb.Federation.SignedFetch

  def show(conn, _params) do
    with {:disclosing, true} <- {:disclosing, BlockSync.disclosing?()},
         {:ok, owner} <- SignedFetch.signer(conn),
         auth when is_binary(auth) <- Sync.authority(owner),
         {:peer, true} <- {:peer, BlockSync.disclosed_peer?(auth)} do
      pairs = BlockSync.disclosed_pairs(auth)
      digest = BlockSync.digest(pairs)
      etag = ~s("#{digest}")

      conn =
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("etag", etag)

      if etag in if_none_match(conn) do
        send_resp(conn, 304, "")
      else
        body = %{
          "@context" => [
            "https://www.w3.org/ns/activitystreams",
            %{
              "blockSynchronizationDigest" =>
                "https://w3id.org/fep/070c#blockSynchronizationDigest"
            }
          ],
          "id" => BlockSync.endpoint_url(),
          "type" => "OrderedCollection",
          "totalItems" => length(pairs),
          "blockSynchronizationDigest" => digest,
          "orderedItems" =>
            Enum.map(pairs, fn {actor, object} ->
              %{"type" => "Block", "actor" => actor, "object" => object}
            end)
        }

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode_to_iodata!(body))
      end
    else
      {:disclosing, false} -> conn |> put_status(:not_found) |> json(%{"error" => "Not Found"})
      {:peer, false} -> conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})
      _ -> conn |> put_status(:unauthorized) |> json(%{"error" => "Unauthorized"})
    end
  end

  defp if_none_match(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
  end
end
