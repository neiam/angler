defmodule AnglerWeb.Federation.SignedFetch do
  @moduledoc """
  Who signed a GET: verifies the request's HTTP signature and returns the
  actor that owns the key. Used by the endpoints that answer only signed
  fetches (FEP-8fcf followers sync, FEP-070c block sync), as upstream's
  ActivityPubSignedFetchService::verify.
  """

  alias Angler.Federation.{Actor, HTTPSignature, HttpSignatureKey}
  alias Angler.Repo

  @spec signer(Plug.Conn.t()) :: {:ok, String.t()} | {:error, term()}
  def signer(%Plug.Conn{} = conn) do
    headers = [{"host", conn.host} | conn.req_headers]

    path =
      if conn.query_string == "",
        do: conn.request_path,
        else: conn.request_path <> "?" <> conn.query_string

    with {:ok, key_id} <- HTTPSignature.verify_fetch(path, headers, &Actor.public_key_for/1) do
      case Repo.get_by(HttpSignatureKey, key_id: key_id) do
        %HttpSignatureKey{owner_url: owner} -> {:ok, owner}
        nil -> {:ok, key_id |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()}
      end
    end
  end
end
