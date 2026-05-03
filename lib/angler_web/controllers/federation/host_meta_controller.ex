defmodule AnglerWeb.Federation.HostMetaController do
  @moduledoc """
  GET /.well-known/host-meta — XRD pointing at our webfinger endpoint.

  See `plans/federation/endpoints/get_well_known_host_meta.md`.
  """

  use AnglerWeb, :controller

  def show(conn, _params) do
    template = AnglerWeb.Endpoint.url() <> "/.well-known/webfinger?resource={uri}"

    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
        ~s(<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">) <>
        ~s(<Link rel="lrdd" type="application/xrd+xml" template="#{template}"/>) <>
        ~s(</XRD>)

    conn
    |> put_resp_content_type("application/xrd+xml")
    |> send_resp(200, body)
  end
end
