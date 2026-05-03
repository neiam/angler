defmodule AnglerWeb.MastodonAPI.MarkerController do
  @moduledoc """
  GET  /api/v1/markers?timeline[]=home&timeline[]=notifications
  POST /api/v1/markers   body: home[last_read_id]=...&notifications[last_read_id]=...
  """

  use AnglerWeb, :controller

  alias Angler.Markers
  alias Angler.Markers.Marker
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    requested = List.wrap(params["timeline"])
    rows = Markers.get(profile.id, requested)
    json(conn, render_map(rows))
  end

  def update(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    updated =
      ["home", "notifications"]
      |> Enum.reduce(%{}, fn timeline, acc ->
        case extract_last_read(params, timeline) do
          nil ->
            acc

          last_read_id ->
            case Markers.set(profile.id, timeline, last_read_id) do
              {:ok, marker} -> Map.put(acc, timeline, marker)
              _ -> acc
            end
        end
      end)

    json(conn, render_map(updated))
  end

  defp extract_last_read(params, key) do
    case params[key] do
      %{"last_read_id" => v} -> parse_int(v)
      v when is_binary(v) -> parse_int(v)
      v when is_integer(v) -> v
      _ -> nil
    end
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(_), do: nil

  defp render_map(rows) when is_map(rows) do
    Map.new(rows, fn {k, %Marker{} = m} ->
      {k,
       %{
         "last_read_id" => Integer.to_string(m.last_read_id),
         "version" => m.version,
         "updated_at" => DateTime.to_iso8601(m.updated_at)
       }}
    end)
  end
end
