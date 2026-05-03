defmodule AnglerWeb.MastodonAPI.FilterController do
  @moduledoc """
    * GET    /api/v2/filters             — list
    * POST   /api/v2/filters             — create
    * GET    /api/v2/filters/:id         — fetch
    * PUT    /api/v2/filters/:id         — update
    * DELETE /api/v2/filters/:id         — delete

  v1 endpoints (legacy single-keyword shape) emit Mastodon's flattened form:

      {"id":"1","phrase":"x","context":["home"],"whole_word":false,"expires_at":null,"irreversible":false}

  We synthesize one v1-shape row per `(filter, keyword)` pair so clients on
  the older protocol still see the same data.
  """

  use AnglerWeb, :controller

  alias Angler.Filters
  alias Angler.Filters.Filter
  alias AnglerWeb.Plugs.BearerAuth

  ## v2

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, Enum.map(Filters.list(profile.id), &render_v2/1))
  end

  def show(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = filter <- Filters.get(profile.id, int_id) do
      json(conn, render_v2(filter))
    else
      _ -> not_found(conn)
    end
  end

  def create(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    case Filters.create(profile.id, params) do
      {:ok, filter} -> json(conn, render_v2(filter))
      {:error, cs} -> validation_error(conn, cs)
    end
  end

  def update(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = filter <- Filters.get(profile.id, int_id),
         {:ok, updated} <- Filters.update(filter, params) do
      json(conn, render_v2(updated))
    else
      {:error, cs} -> validation_error(conn, cs)
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = filter <- Filters.get(profile.id, int_id) do
      :ok = Filters.delete(filter)
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  ## v1 (legacy)

  def index_v1(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    body =
      Filters.list(profile.id)
      |> Enum.flat_map(&v1_rows_for/1)

    json(conn, body)
  end

  ## Internals

  defp render_v2(%Filter{} = f) do
    %{
      "id" => Integer.to_string(f.id),
      "title" => f.title,
      "context" => f.contexts,
      "filter_action" => f.filter_action,
      "expires_at" =>
        case f.expires_at do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end,
      "keywords" =>
        Enum.map(f.keywords, fn k ->
          %{
            "id" => Integer.to_string(k.id),
            "keyword" => k.keyword,
            "whole_word" => k.whole_word
          }
        end),
      "statuses" => []
    }
  end

  defp v1_rows_for(%Filter{} = f) do
    Enum.map(f.keywords, fn k ->
      %{
        "id" => Integer.to_string(k.id),
        "phrase" => k.keyword,
        "context" => f.contexts,
        "whole_word" => k.whole_word,
        "expires_at" =>
          case f.expires_at do
            %DateTime{} = dt -> DateTime.to_iso8601(dt)
            _ -> nil
          end,
        "irreversible" => f.filter_action == "hide"
      }
    end)
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

  defp validation_error(conn, cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "Validation failed", "errors" => errors})
  end
end
