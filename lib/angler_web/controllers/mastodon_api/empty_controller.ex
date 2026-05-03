defmodule AnglerWeb.MastodonAPI.EmptyController do
  @moduledoc """
  Endpoints whose Mastodon-spec response is "always an empty array (or
  empty object) for now". Mobile clients query these on bootstrap and
  don't tolerate 404s — a 200 with `[]` makes them happy until a real
  implementation lands.
  """

  use AnglerWeb, :controller

  def empty_array(conn, _params), do: json(conn, [])
  def empty_object(conn, _params), do: json(conn, %{})
end
