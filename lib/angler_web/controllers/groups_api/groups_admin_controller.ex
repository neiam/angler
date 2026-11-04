defmodule AnglerWeb.GroupsAPI.GroupsAdminController do
  @moduledoc """
  Per-group admin tools (blocks, reports, admin-tabs). Most actions
  require admin/owner role within the group; the context layer enforces
  this and returns `{:error, :forbidden}` on mismatches.

  Some Pixelfed-shape endpoints we don't yet back with a real tracker
  (interaction logs, mbs/meta-block-search, export). Those return empty
  arrays so the UI doesn't 404; everything else is real.
  """

  use AnglerWeb, :controller

  alias Angler.Groups
  alias Angler.Groups.{Block, Group, Report}
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  ## Admin tabs — mostly a router for the mobile UI; return a fixed list.

  def admin_tabs(conn, _params) do
    if Groups.enabled?() do
      json(conn, %{
        "tabs" => [
          %{"key" => "members", "label" => "Members"},
          %{"key" => "requests", "label" => "Join Requests"},
          %{"key" => "reports", "label" => "Reports"},
          %{"key" => "blocks", "label" => "Blocks"}
        ]
      })
    else
      not_found(conn)
    end
  end

  def admin_interactions(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, []), else: not_found(conn))

  def admin_mbs(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, []), else: not_found(conn))

  ## Blocks

  def admin_blocks(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      json(conn, Enum.map(Groups.list_blocks(group), &render_block/1))
    end)
  end

  def admin_blocks_add(conn, %{"id" => id} = params) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      with {:ok, target} <- require_int(params, "pid"),
           {:ok, _} <- Groups.block(actor, group, target, params["reason"]) do
        json(conn, %{"code" => 200})
      else
        {:error, :missing} -> validation_error(conn, %{"pid" => ["is required"]})
        {:error, :forbidden} -> forbidden(conn)
        {:error, _} -> not_found(conn)
      end
    end)
  end

  def admin_blocks_undo(conn, %{"id" => id} = params) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case require_int(params, "pid") do
        {:ok, target} ->
          case Groups.unblock(actor, group, target) do
            :ok -> json(conn, %{"code" => 200})
            {:error, :forbidden} -> forbidden(conn)
          end

        {:error, :missing} ->
          validation_error(conn, %{"pid" => ["is required"]})
      end
    end)
  end

  def admin_blocks_export(conn, %{"id" => id}) do
    # Return JSON of the current blocks. Real exports would generate a
    # downloadable artifact; this matches Pixelfed's API response shape.
    with_group(conn, id, fn group ->
      json(conn, %{
        "domain" => host(),
        "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "blocks" => Enum.map(Groups.list_blocks(group), &render_block/1)
      })
    end)
  end

  ## Reports

  def reports_list(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      json(conn, Enum.map(Groups.list_reports(group), &render_report/1))
    end)
  end

  def report_create(conn, %{"id" => id} = params) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.report(actor, group, params) do
        {:ok, _r} ->
          json(conn, %{"code" => 200, "msg" => "Report submitted"})

        {:error, %Ecto.Changeset{} = cs} ->
          validation_error(conn, traverse(cs))

        {:error, reason} ->
          validation_error(conn, %{"error" => [to_string(reason)]})
      end
    end)
  end

  def report_action(conn, %{"id" => id} = params) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case require_int(params, "report_id") do
        {:ok, rid} ->
          case Groups.resolve_report(actor, group, rid) do
            {:ok, _} -> json(conn, %{"code" => 200})
            {:error, :forbidden} -> forbidden(conn)
            {:error, _} -> not_found(conn)
          end

        {:error, :missing} ->
          validation_error(conn, %{"report_id" => ["is required"]})
      end
    end)
  end

  ## Renderers

  defp render_block(%Block{} = b) do
    %{
      "id" => Integer.to_string(b.id),
      "profile_id" => Integer.to_string(b.profile_id),
      "reason" => b.reason,
      "blocked_at" => DateTime.to_iso8601(b.inserted_at),
      "account" => b.profile && Account.render(b.profile)
    }
  end

  defp render_report(%Report{} = r) do
    %{
      "id" => Integer.to_string(r.id),
      "object_type" => r.object_type,
      "object_id" => r.object_id,
      "report_type" => r.report_type,
      "message" => r.message,
      "created_at" => DateTime.to_iso8601(r.inserted_at)
    }
  end

  ## Internals

  defp with_group(conn, id, fun) do
    if Groups.enabled?() do
      case Groups.get(id) do
        nil -> not_found(conn)
        %Group{} = g -> fun.(g)
      end
    else
      not_found(conn)
    end
  end

  defp require_int(params, key) do
    case params[key] do
      n when is_integer(n) ->
        {:ok, n}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _ -> {:error, :missing}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp host do
    AnglerWeb.Endpoint.url() |> URI.parse() |> Map.get(:host) || "localhost"
  end

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})

  defp forbidden(conn),
    do: conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})

  defp traverse(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
