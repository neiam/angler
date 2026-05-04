defmodule AnglerWeb.MastodonAPI.ListController do
  @moduledoc """
    * GET    /api/v1/lists                    — owned lists
    * POST   /api/v1/lists                    — create
    * GET    /api/v1/lists/:id                — fetch one
    * PUT    /api/v1/lists/:id                — update
    * DELETE /api/v1/lists/:id                — delete
    * GET    /api/v1/lists/:id/accounts       — members
    * POST   /api/v1/lists/:id/accounts       — add account_ids[]
    * DELETE /api/v1/lists/:id/accounts       — remove account_ids[]
    * GET    /api/v1/timelines/list/:id       — list timeline
  """

  use AnglerWeb, :controller

  alias Angler.Lists
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    json(conn, Enum.map(Lists.list_for(profile.id), &render_list/1))
  end

  def show(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = list <- Lists.get(profile.id, int_id) do
      json(conn, render_list(list))
    else
      _ -> not_found(conn)
    end
  end

  def create(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    case Lists.create(profile.id, params) do
      {:ok, list} -> json(conn, render_list(list))
      {:error, cs} -> validation_error(conn, cs)
    end
  end

  def update(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = list <- Lists.get(profile.id, int_id),
         {:ok, updated} <- Lists.update(list, params) do
      json(conn, render_list(updated))
    else
      {:error, cs} -> validation_error(conn, cs)
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = list <- Lists.get(profile.id, int_id) do
      :ok = Lists.delete(list)
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  def accounts(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = list <- Lists.get(profile.id, int_id) do
      json(conn, Enum.map(Lists.accounts(list), &Account.render/1))
    else
      _ -> not_found(conn)
    end
  end

  def add_accounts(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = list <- Lists.get(profile.id, int_id) do
      :ok = Lists.add_accounts(list, parse_account_ids(params["account_ids"]))
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  def remove_accounts(conn, %{"id" => id} = params) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = list <- Lists.get(profile.id, int_id) do
      :ok = Lists.remove_accounts(list, parse_account_ids(params["account_ids"]))
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  def timeline(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %_{} = list <- Lists.get(profile.id, int_id) do
      statuses = Lists.timeline(list)
      json(conn, StatusJSON.render_many(statuses, profile.id))
    else
      _ -> not_found(conn)
    end
  end

  ## Internals

  defp render_list(list) do
    %{
      "id" => Integer.to_string(list.id),
      "title" => list.title,
      "replies_policy" => list.replies_policy,
      "exclusive" => list.exclusive
    }
  end

  defp parse_account_ids(nil), do: []
  defp parse_account_ids([]), do: []

  defp parse_account_ids(list) when is_list(list) do
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

  defp parse_account_ids(_), do: []

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
