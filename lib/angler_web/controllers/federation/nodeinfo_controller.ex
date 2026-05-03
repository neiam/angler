defmodule AnglerWeb.Federation.NodeinfoController do
  @moduledoc """
  Nodeinfo discovery + 2.0 document.

  See:
  * `plans/federation/endpoints/get_well_known_nodeinfo.md`
  * `plans/federation/endpoints/get_nodeinfo_document.md`
  """

  use AnglerWeb, :controller

  alias Angler.Federation.Nodeinfo

  def well_known(conn, _params) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> json(Nodeinfo.well_known())
  end

  def document(conn, _params) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> json(Nodeinfo.document())
  end
end
