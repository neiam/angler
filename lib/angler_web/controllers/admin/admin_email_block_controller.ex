defmodule AnglerWeb.Admin.EmailDomainBlockController do
  @moduledoc """
    * GET    /api/v1/admin/email_domain_blocks
    * POST   /api/v1/admin/email_domain_blocks  (domain=)
    * DELETE /api/v1/admin/email_domain_blocks/:id
  """

  use AnglerWeb, :controller

  alias Angler.Admin
  alias Angler.Admin.EmailDomainBlock

  def index(conn, _params) do
    json(conn, Enum.map(Admin.list_email_domain_blocks(), &render_one/1))
  end

  def create(conn, params) do
    case Admin.create_email_domain_block(params) do
      {:ok, block} -> json(conn, render_one(block))
      {:error, cs} -> validation_error(conn, cs)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %EmailDomainBlock{} = block <- Admin.get_email_domain_block(int_id) do
      :ok = Admin.delete_email_domain_block(block)
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  defp render_one(%EmailDomainBlock{} = b) do
    %{
      "id" => Integer.to_string(b.id),
      "domain" => b.domain,
      "created_at" =>
        case b.inserted_at do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end,
      "history" => []
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
