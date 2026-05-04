defmodule AnglerWeb.Admin.DomainBlockController do
  @moduledoc """
    * GET    /api/v1/admin/domain_blocks
    * GET    /api/v1/admin/domain_blocks/:id
    * POST   /api/v1/admin/domain_blocks
    * PUT    /api/v1/admin/domain_blocks/:id
    * DELETE /api/v1/admin/domain_blocks/:id
  """

  use AnglerWeb, :controller

  alias Angler.Admin
  alias Angler.Admin.InstanceDomainBlock

  def index(conn, _params) do
    json(conn, Enum.map(Admin.list_instance_domain_blocks(), &render_one/1))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %InstanceDomainBlock{} = block <- Admin.get_instance_domain_block(int_id) do
      json(conn, render_one(block))
    else
      _ -> not_found(conn)
    end
  end

  def create(conn, params) do
    case Admin.create_instance_domain_block(params) do
      {:ok, block} -> json(conn, render_one(block))
      {:error, cs} -> validation_error(conn, cs)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, int_id} <- parse_id(id),
         %InstanceDomainBlock{} = block <- Admin.get_instance_domain_block(int_id),
         {:ok, updated} <- Admin.update_instance_domain_block(block, params) do
      json(conn, render_one(updated))
    else
      {:error, cs} -> validation_error(conn, cs)
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %InstanceDomainBlock{} = block <- Admin.get_instance_domain_block(int_id) do
      :ok = Admin.delete_instance_domain_block(block)
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  defp render_one(%InstanceDomainBlock{} = b) do
    %{
      "id" => Integer.to_string(b.id),
      "domain" => b.domain,
      "severity" => b.severity,
      "reject_media" => b.reject_media,
      "reject_reports" => b.reject_reports,
      "public_comment" => b.public_comment,
      "private_comment" => b.private_comment,
      "obfuscate" => b.obfuscate,
      "created_at" =>
        case b.inserted_at do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end
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
