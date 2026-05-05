defmodule AnglerWeb.PixelfedAdmin.AdminController do
  @moduledoc """
  Pixelfed-shape admin namespace at `/api/admin/...`. Distinct from the
  Mastodon-shape admin surface at `/api/v1/admin/...`. Mounts on the
  existing `:admin_read` / `:admin_write` pipelines (moderator+ for reads,
  admin for writes).
  """

  use AnglerWeb, :controller

  alias Angler.Accounts.User
  alias Angler.Admin.Pixelfed, as: AdminCtx
  alias Angler.Federation.Instance
  alias Angler.Profiles.Profile
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Account, as: AccountJSON
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /supported

  def supported(conn, _params), do: json(conn, %{"supported" => true})

  ## GET /stats

  def stats(conn, _params), do: json(conn, AdminCtx.summary())

  ## GET /instance/stats

  def all_stats(conn, _params), do: json(conn, AdminCtx.all_stats())

  ## Mod reports

  def mod_reports_list(conn, params) do
    limit = parse_limit(params["limit"], 20, 50)
    json(conn, AdminCtx.mod_reports(limit))
  end

  def mod_reports_handle(conn, params) do
    %{user: actor} = BearerAuth.current_scope(conn)

    with {:ok, id} <- require_field(params, "id"),
         {:ok, action} <- require_field(params, "action"),
         {:ok, body} <- AdminCtx.handle_mod_report(actor, id, action) do
      json(conn, body)
    else
      {:error, :missing_field} -> bad_request(conn, "Missing required field")
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_action} -> bad_request(conn, "Invalid action")
      {:error, :invalid_id} -> bad_request(conn, "Invalid id")
    end
  end

  ## Autospam (stubbed — see Angler.Admin.Pixelfed)

  def autospam_list(conn, _params), do: json(conn, AdminCtx.autospam_list())

  def autospam_handle(conn, _params), do: not_found(conn)

  ## Configuration

  def config_get(conn, _params), do: json(conn, AdminCtx.config_list())

  def config_update(conn, params) do
    %{user: actor} = BearerAuth.current_scope(conn)

    with {:ok, key} <- require_field(params, "key"),
         {:ok, value} <- require_field(params, "value"),
         {:ok, list} <- AdminCtx.update_config(actor, key, value) do
      json(conn, list)
    else
      {:error, :missing_field} -> bad_request(conn, "Missing required field")
      {:error, :unknown_key} -> bad_request(conn, "Invalid cache key.")
    end
  end

  ## Users

  def users_list(conn, params) do
    %{users: users, next_max_id: next} = AdminCtx.users_list(params)

    body =
      Enum.map(users, fn %User{profile: %Profile{} = p} = u ->
        render_admin_user(u, p)
      end)

    json(conn, %{"data" => body, "next_max_id" => next})
  end

  def users_get(conn, params) do
    case AdminCtx.get_user(params["user_id"]) do
      nil ->
        not_found(conn)

      %User{profile: %Profile{} = p} = user ->
        json(conn, render_admin_user(user, p, with_meta: true))
    end
  end

  def users_action(conn, params) do
    %{user: actor} = BearerAuth.current_scope(conn)

    with {:ok, id} <- require_field(params, "id"),
         {:ok, action} <- require_field(params, "action") do
      case AdminCtx.user_action(actor, id, action, params["value"]) do
        {:ok, %User{profile: %Profile{} = p} = user} ->
          json(conn, render_admin_user(user, p, with_meta: true))

        {:error, :cannot_moderate_admin} ->
          bad_request(conn, "Cannot moderate admin accounts")

        {:error, :deletion_disabled} ->
          not_found(conn)

        {:error, :not_found} ->
          not_found(conn)

        {:error, :invalid_action} ->
          bad_request(conn, "Invalid action")

        {:error, :invalid_id} ->
          bad_request(conn, "Invalid id")
      end
    else
      {:error, :missing_field} -> bad_request(conn, "Missing required field")
    end
  end

  ## Instances

  def instances_list(conn, params) do
    %{instances: rows, next_max_id: next} = AdminCtx.instances_list(params)
    json(conn, %{"data" => Enum.map(rows, &render_instance/1), "next_max_id" => next})
  end

  def instances_get(conn, params) do
    case AdminCtx.get_instance(params["id"]) do
      nil -> not_found(conn)
      %Instance{} = inst -> json(conn, render_instance(inst))
    end
  end

  def instances_moderate(conn, params) do
    %{user: actor} = BearerAuth.current_scope(conn)

    with {:ok, id} <- require_field(params, "id"),
         {:ok, key} <- require_field(params, "key"),
         {:ok, value} <- require_field(params, "value"),
         {:ok, inst} <- AdminCtx.moderate_instance(actor, id, key, value) do
      json(conn, render_instance(inst))
    else
      {:error, :missing_field} -> bad_request(conn, "Missing required field")
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_key} -> bad_request(conn, "Invalid key")
    end
  end

  def instances_refresh_stats(conn, params) do
    %{user: actor} = BearerAuth.current_scope(conn)

    with {:ok, id} <- require_field(params, "id"),
         {:ok, inst} <- AdminCtx.refresh_instance_stats(actor, id) do
      json(conn, render_instance(inst))
    else
      {:error, :missing_field} -> bad_request(conn, "Missing required field")
      {:error, :not_found} -> not_found(conn)
    end
  end

  ## Post moderation

  def moderate_post(conn, %{"id" => id} = params) do
    %{user: actor} = BearerAuth.current_scope(conn)

    with {:ok, action} <- require_field(params, "action"),
         {:ok, %Status{} = status} <- AdminCtx.moderate_post(actor, id, action) do
      json(conn, StatusJSON.render(status, nil))
    else
      {:error, :missing_field} ->
        bad_request(conn, "Missing required field")

      {:error, :not_found} ->
        bad_request(conn, "Cannot find status")

      {:error, :cannot_moderate_admin} ->
        bad_request(conn, "Cannot moderate admin accounts")

      {:error, :invalid_action} ->
        bad_request(conn, "Invalid action")
    end
  end

  ## Renderers

  defp render_admin_user(%User{} = user, %Profile{} = profile, opts \\ []) do
    base = %{
      "id" => Integer.to_string(user.id),
      "profile_id" => Integer.to_string(profile.id),
      "username" => profile.username,
      "email" => user.email,
      "is_admin" => !!user.is_admin,
      "is_moderator" => !!user.is_moderator,
      "email_verified" => not is_nil(user.email_verified_at),
      "created_at" => DateTime.to_iso8601(user.inserted_at),
      "status" => user.status,
      "moderation" => %{
        "unlisted" => !!profile.unlisted,
        "cw" => !!profile.cw,
        "no_autolink" => !!profile.no_autolink
      }
    }

    if Keyword.get(opts, :with_meta, false) do
      Map.put(base, "meta", %{
        "cached_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "account" => AccountJSON.render(profile),
        "moderation" => base["moderation"]
      })
    else
      base
    end
  end

  defp render_instance(%Instance{} = inst) do
    %{
      "id" => Integer.to_string(inst.id),
      "domain" => inst.domain,
      "software" => inst.software,
      "version" => inst.version,
      "user_count" => inst.user_count,
      "status_count" => inst.status_count,
      "banned" => !!inst.banned,
      "unlisted" => !!inst.unlisted,
      "auto_cw" => !!inst.auto_cw,
      "ban_severity" => inst.ban_severity,
      "ban_reason" => inst.ban_reason,
      "public_comments" => inst.public_comments,
      "created_at" => DateTime.to_iso8601(inst.inserted_at)
    }
  end

  ## Internals

  defp require_field(params, key) do
    case params[key] do
      v when not is_nil(v) and v != "" -> {:ok, v}
      _ -> {:error, :missing_field}
    end
  end

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(s, default, max) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n |> max(1) |> min(max)
      _ -> default
    end
  end

  defp parse_limit(_, default, _), do: default

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})

  defp bad_request(conn, msg),
    do: conn |> put_status(:bad_request) |> json(%{"error" => msg})
end
