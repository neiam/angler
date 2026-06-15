defmodule AnglerWeb.Admin.RelayController do
  @moduledoc """
  Mastodon-compatible relay administration.

    * GET    /api/v1/admin/relays
    * POST   /api/v1/admin/relays            (param: `actor_url`)
    * POST   /api/v1/admin/relays/:id/enable
    * POST   /api/v1/admin/relays/:id/disable
    * DELETE /api/v1/admin/relays/:id
  """

  use AnglerWeb, :controller

  alias Angler.Federation.Relay
  alias Angler.Federation.Relays

  def index(conn, _params) do
    json(conn, Enum.map(Relays.list(), &render_one/1))
  end

  def create(conn, params) do
    case params["actor_url"] do
      url when is_binary(url) and url != "" ->
        case Relays.subscribe(url) do
          {:ok, relay} ->
            json(conn, render_one(relay))

          {:error, %Ecto.Changeset{} = cs} ->
            validation_error(conn, cs)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{"error" => "Couldn't reach relay: #{inspect(reason)}"})
        end

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "actor_url is required"})
    end
  end

  def enable(conn, %{"id" => id}) do
    with_relay(conn, id, fn relay ->
      {:ok, relay} = Relays.enable(relay)
      json(conn, render_one(relay))
    end)
  end

  def disable(conn, %{"id" => id}) do
    with_relay(conn, id, fn relay ->
      {:ok, relay} = Relays.disable(relay)
      json(conn, render_one(relay))
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_relay(conn, id, fn relay ->
      :ok = Relays.unsubscribe(relay)
      json(conn, %{})
    end)
  end

  ## Internals

  defp with_relay(conn, id, fun) do
    with {:ok, int_id} <- parse_id(id),
         %Relay{} = relay <- Relays.get(int_id) do
      fun.(relay)
    else
      _ -> not_found(conn)
    end
  end

  defp render_one(%Relay{} = r) do
    %{
      "id" => Integer.to_string(r.id),
      "actor" => r.actor_url,
      "inbox_url" => r.inbox_url,
      "state" => Atom.to_string(r.state)
    }
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

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
