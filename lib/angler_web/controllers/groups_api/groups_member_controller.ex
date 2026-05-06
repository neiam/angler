defmodule AnglerWeb.GroupsAPI.GroupsMemberController do
  @moduledoc """
  Members + invitations + per-member admin ops on `/api/v0/groups/...`.
  All endpoints respect `:groups_enabled`.
  """

  use AnglerWeb, :controller

  alias Angler.Groups
  alias Angler.Groups.{Group, Member}
  alias Angler.Profiles
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  ## Members + requests

  def members_list(conn, params) do
    with_group(conn, params["id"], fn group ->
      members = Groups.members(group)
      json(conn, Enum.map(members, &render_member/1))
    end)
  end

  def members_get(conn, params) do
    with_group(conn, params["id"], fn group ->
      pid = parse_id_or_nil(params["pid"])

      case pid && Profiles.get_profile(pid) do
        nil ->
          not_found(conn)

        %Profiles.Profile{} = profile ->
          if Groups.member?(group, profile) do
            json(conn, Account.render(profile))
          else
            not_found(conn)
          end
      end
    end)
  end

  def members_requests(conn, params) do
    with_group(conn, params["id"], fn group ->
      json(conn, Enum.map(Groups.pending_requests(group), &render_member/1))
    end)
  end

  def members_request_handle(conn, params) do
    with_group(conn, params["id"], fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)
      target = parse_id_or_nil(params["pid"])

      case Groups.accept_request(actor, group, target) do
        {:ok, _m} -> json(conn, %{"code" => 200})
        {:error, :forbidden} -> forbidden(conn)
        {:error, _} -> not_found(conn)
      end
    end)
  end

  def member_intersect_common(conn, _params) do
    # Pixelfed returns common members between two profiles. We don't
    # surface that today; empty-list is the safe stub.
    if Groups.enabled?(), do: json(conn, []), else: not_found(conn)
  end

  ## Account-by-pid lookup (`/accounts/:gid/:pid`)

  def account_in_group(conn, %{"gid" => gid, "pid" => pid}) do
    with_group(conn, gid, fn group ->
      case Profiles.get_profile(parse_id_or_nil(pid)) do
        nil ->
          not_found(conn)

        profile ->
          base = Account.render(profile)
          json(conn, Map.put(base, "is_member", Groups.member?(group, profile)))
      end
    end)
  end

  ## Joins / leaves / cancel-join-request

  def join(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.join(actor, group) do
        {:ok, :member, _} -> json(conn, %{"code" => 200, "state" => "member"})
        {:ok, :pending, _} -> json(conn, %{"code" => 200, "state" => "pending"})
        {:error, :already_member} -> json(conn, %{"code" => 200, "state" => "member"})
        {:error, :blocked} -> forbidden(conn)
      end
    end)
  end

  def leave(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.leave(actor, group) do
        :ok ->
          json(conn, %{"code" => 200})

        {:error, :owner_cannot_leave} ->
          validation_error(conn, %{
            "error" => ["owner cannot leave; transfer ownership or delete the group"]
          })

        {:error, :not_a_member} ->
          not_found(conn)
      end
    end)
  end

  def cancel_join_request(conn, %{"id" => id}) do
    # Pixelfed `cjr` — same as leaving when membership is still pending.
    leave(conn, %{"id" => id})
  end

  ## Invitations

  def invite_check(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.invite_check(actor, group) do
        :pending -> json(conn, %{"code" => 200, "state" => "pending"})
        {:error, :not_found} -> not_found(conn)
      end
    end)
  end

  def invite_accept(conn, %{"id" => id}) do
    # Accepting an invite is the same as joining; the join path checks
    # for an outstanding invite and short-circuits the approval step.
    join(conn, %{"id" => id})
  end

  def invite_decline(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.decline_invite(actor, group) do
        :ok -> json(conn, %{"code" => 200})
        {:error, :not_found} -> not_found(conn)
      end
    end)
  end

  ## Member interaction limits — stubbed
  ##
  ## Pixelfed exposes per-member can-post / can-comment toggles. Our
  ## current data model has group-level policies but not per-member
  ## overrides. Mount empty/200 stubs so the admin UI doesn't break.

  def get_interaction_limits(conn, _params) do
    if Groups.enabled?(), do: json(conn, %{"limits" => %{}}), else: not_found(conn)
  end

  def update_interaction_limits(conn, _params) do
    if Groups.enabled?(), do: json(conn, %{"code" => 200}), else: not_found(conn)
  end

  ## Friend invitation search/send — stubbed
  ##
  ## Pixelfed has a "find friends to invite" subflow. Not implemented;
  ## returning empty arrays keeps the UI functional.

  def search_invite_friends(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, []), else: not_found(conn))

  def search_invite_send(conn, _params),
    do: if(Groups.enabled?(), do: json(conn, %{"code" => 200}), else: not_found(conn))

  ## Renderers

  defp render_member(%Member{} = m) do
    %{
      "id" => Integer.to_string(m.id),
      "role" => m.role,
      "joined_at" => m.accepted_at && DateTime.to_iso8601(m.accepted_at),
      "account" => Account.render(m.profile)
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

  defp parse_id_or_nil(nil), do: nil
  defp parse_id_or_nil(n) when is_integer(n), do: n

  defp parse_id_or_nil(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id_or_nil(_), do: nil

  defp not_found(conn),
    do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})

  defp forbidden(conn),
    do: conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})
end
