defmodule AnglerWeb.GroupsAPI.GroupsController do
  @moduledoc """
  Pixelfed `/api/v0/groups/...` namespace — lifecycle + reads.

  All endpoints respect the `:groups_enabled` config flag (404 when off).
  Mounted on `:authenticated_read` for reads and `:authenticated_write`
  for the few writes implemented here.

  Search/admin/post-specific endpoints live in sibling controllers.
  """

  use AnglerWeb, :controller

  alias Angler.Groups
  alias Angler.Groups.{Category, Group}
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.Plugs.BearerAuth

  ## Capability config

  def config(conn, _params) do
    enabled? = Groups.enabled?()
    json(conn, %{"enabled" => enabled?, "version" => "0.1"})
  end

  ## Permission probe

  def can_create?(conn, _params) do
    if Groups.enabled?() do
      json(conn, %{"can_create" => true, "remaining_quota" => 5})
    else
      not_found(conn)
    end
  end

  ## POST create

  def create(conn, params) do
    if Groups.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)

      case Groups.create(profile, params) do
        {:ok, group} ->
          json(conn, render_group(group, profile.id))

        {:error, :name_required} ->
          validation_error(conn, %{"name" => ["is required"]})

        {:error, %Ecto.Changeset{} = cs} ->
          validation_error(conn, traverse(cs))

        {:error, reason} ->
          validation_error(conn, %{"error" => [to_string(reason)]})
      end
    else
      not_found(conn)
    end
  end

  ## DELETE

  def delete(conn, %{"id" => id} = _params) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.delete(actor, group) do
        :ok -> json(conn, %{"code" => 200, "msg" => "Group deleted"})
        {:error, :forbidden} -> forbidden(conn)
      end
    end)
  end

  ## GET single

  def show(conn, %{"id" => id}) do
    with_group(conn, id, fn group ->
      viewer_id = viewer_id(conn)
      json(conn, render_group(group, viewer_id))
    end)
  end

  ## POST settings (update)

  def update(conn, %{"id" => id} = params) do
    with_group(conn, id, fn group ->
      %{profile: actor} = BearerAuth.current_scope(conn)

      case Groups.update(actor, group, params) do
        {:ok, updated} -> json(conn, render_group(updated, actor.id))
        {:error, :forbidden} -> forbidden(conn)
        {:error, %Ecto.Changeset{} = cs} -> validation_error(conn, traverse(cs))
      end
    end)
  end

  ## Categories

  def categories_list(conn, _params) do
    if Groups.enabled?() do
      body =
        Groups.list_categories()
        |> Enum.map(fn %Category{} = c ->
          %{"id" => Integer.to_string(c.id), "name" => c.name, "slug" => c.slug}
        end)

      json(conn, body)
    else
      not_found(conn)
    end
  end

  def category_groups(conn, params) do
    if Groups.enabled?() do
      cat_id = params["id"]
      groups = Groups.recent(40) |> Enum.filter(&(to_string(&1.category_id) == to_string(cat_id)))
      viewer_id = viewer_id(conn)
      json(conn, Enum.map(groups, &render_group(&1, viewer_id)))
    else
      not_found(conn)
    end
  end

  ## Discovery

  def discover_popular(conn, _params) do
    if Groups.enabled?() do
      viewer_id = viewer_id(conn)
      json(conn, Enum.map(Groups.popular(20), &render_group(&1, viewer_id)))
    else
      not_found(conn)
    end
  end

  def discover_new(conn, _params) do
    if Groups.enabled?() do
      viewer_id = viewer_id(conn)
      json(conn, Enum.map(Groups.recent(20), &render_group(&1, viewer_id)))
    else
      not_found(conn)
    end
  end

  ## Self lists

  def self_list(conn, _params) do
    if Groups.enabled?() do
      %{profile: profile} = BearerAuth.current_scope(conn)
      json(conn, Enum.map(Groups.list_for_profile(profile), &render_group(&1, profile.id)))
    else
      not_found(conn)
    end
  end

  def self_recommended(conn, _params) do
    # Recommendations can mirror popular for now; clients consume the
    # same shape and there's no operator-side recommendation pipeline.
    discover_popular(conn, %{})
  end

  ## Renderers

  defp render_group(%Group{} = g, viewer_id) do
    is_member = viewer_id && Groups.member?(g, viewer_id)

    %{
      "id" => Integer.to_string(g.id),
      "name" => g.name,
      "slug" => g.slug,
      "description" => g.description,
      "privacy" => g.privacy,
      "discoverable" => g.discoverable,
      "post_policy" => g.post_policy,
      "comment_policy" => g.comment_policy,
      "avatar" => g.avatar_path || "",
      "header" => g.header_path || "",
      "member_count" => g.member_count,
      "post_count" => g.post_count,
      "category_id" => g.category_id && Integer.to_string(g.category_id),
      "owner" =>
        case g.owner_profile_id do
          nil ->
            nil

          oid ->
            case Angler.Repo.get(Angler.Profiles.Profile, oid) do
              nil -> nil
              p -> Account.render(p)
            end
        end,
      "is_member" => is_member,
      "created_at" => DateTime.to_iso8601(g.inserted_at)
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

  defp viewer_id(conn) do
    case BearerAuth.current_scope(conn) do
      %{profile: %{id: pid}} -> pid
      _ -> nil
    end
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
