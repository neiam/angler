defmodule AnglerWeb.Admin.AccountController do
  @moduledoc """
    * GET    /api/v1/admin/accounts
    * GET    /api/v1/admin/accounts/:id
    * POST   /api/v1/admin/accounts/:id/action
    * POST   /api/v1/admin/accounts/:id/{unsuspend,unsilence,enable}
    * DELETE /api/v1/admin/accounts/:id    — purge content
  """

  use AnglerWeb, :controller

  alias Angler.Admin
  alias Angler.Profiles.Profile
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  def index(conn, params) do
    opts = []

    opts =
      case params["local"] do
        v when v in ["true", true] -> Keyword.put(opts, :local, true)
        _ -> opts
      end

    opts =
      case params["remote"] do
        v when v in ["true", true] -> Keyword.put(opts, :local, false)
        _ -> opts
      end

    opts =
      case params["suspended"] do
        v when v in ["true", true] -> Keyword.put(opts, :suspended, true)
        _ -> opts
      end

    json(conn, Enum.map(Admin.list_accounts(opts), &render_admin_account/1))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Admin.get_account(int_id) do
      json(conn, render_admin_account(profile))
    else
      _ -> not_found(conn)
    end
  end

  def act(conn, %{"id" => id} = params) do
    %{profile: moderator} = BearerAuth.current_scope(conn)
    type = params["type"] || "none"

    opts = [
      text: params["text"],
      notify: truthy?(params["send_email_notification"]),
      report_id: parse_optional_id(params["report_id"])
    ]

    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Admin.get_account(int_id),
         {:ok, _} <- Admin.act_on_account(profile, moderator, type, opts) do
      json(conn, %{})
    else
      {:error, :invalid_action} -> validation_error(conn, "invalid action")
      _ -> not_found(conn)
    end
  end

  def unsuspend(conn, %{"id" => id}), do: do_reverse(conn, id, &Admin.unsuspend/1)
  def unsilence(conn, %{"id" => id}), do: do_reverse(conn, id, &Admin.unsilence/1)
  def enable(conn, %{"id" => id}), do: do_reverse(conn, id, &Admin.enable/1)

  defp do_reverse(conn, id, fun) do
    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Admin.get_account(int_id),
         {:ok, updated} <- fun.(profile) do
      json(conn, render_admin_account(updated))
    else
      _ -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Admin.get_account(int_id) do
      :ok = Admin.purge_account(profile)
      json(conn, %{})
    else
      _ -> not_found(conn)
    end
  end

  ## Internals

  defp render_admin_account(%Profile{} = p) do
    base = Account.render(p)

    Map.merge(base, %{
      "id" => Integer.to_string(p.id),
      "username" => p.username,
      "domain" => p.domain,
      "email" => nil,
      "ip" => nil,
      "role" => %{"name" => "User"},
      "confirmed" => true,
      "suspended" => p.is_suspended,
      "silenced" => p.status == "silenced",
      "disabled" => p.status == "disabled",
      "approved" => true,
      "account" => base
    })
  end

  defp parse_id(nil), do: :error

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp parse_optional_id(nil), do: nil

  defp parse_optional_id(id) do
    case parse_id(id) do
      {:ok, n} -> n
      _ -> nil
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})

  defp validation_error(conn, msg),
    do: conn |> put_status(:unprocessable_entity) |> json(%{"error" => msg})
end
