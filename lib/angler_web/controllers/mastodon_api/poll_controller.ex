defmodule AnglerWeb.MastodonAPI.PollController do
  @moduledoc """
  GET /api/v1/polls/:id          — read poll (with viewer's votes overlaid).
  POST /api/v1/polls/:id/votes   — submit `choices: [idx]` (single or multi).
  """

  use AnglerWeb, :controller

  alias Angler.Polls
  alias AnglerWeb.MastodonAPI.Poll, as: PollJSON
  alias AnglerWeb.Plugs.BearerAuth

  def show(conn, %{"id" => id}) do
    viewer_id =
      case BearerAuth.current_scope(conn) do
        %{profile: %{id: pid}} -> pid
        _ -> nil
      end

    with {:ok, int_id} <- parse_id(id),
         %_{} = poll <- Polls.get(int_id) do
      json(conn, PollJSON.render(poll, viewer_id))
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def vote(conn, %{"id" => id} = params) do
    %{profile: voter} = BearerAuth.current_scope(conn)
    choices = parse_choices(params["choices"])

    with {:ok, int_id} <- parse_id(id),
         %_{} = poll <- Polls.get(int_id),
         {:ok, updated} <- Polls.vote(poll, voter, choices) do
      json(conn, PollJSON.render(updated, voter.id))
    else
      {:error, reason} when is_atom(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => Atom.to_string(reason)})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp parse_choices(nil), do: []
  defp parse_choices([]), do: []

  defp parse_choices(list) when is_list(list) do
    Enum.flat_map(list, fn
      n when is_integer(n) ->
        [n]

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} -> [n]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp parse_choices(_), do: []
end
