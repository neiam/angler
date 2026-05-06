defmodule Angler.Groups do
  @moduledoc """
  Pixelfed-style community groups. Whole feature is gated by the
  `:groups_enabled` config flag (default `false`); when off, every
  endpoint short-circuits to a 404 at the controller layer.

  ## Lifecycle

    * `create/2` — owner profile becomes the first member with `role:
      "owner"`. Slug is derived from the name (downcased + dashed).
    * `get/1`, `get_by_slug/1` — single-row lookups.
    * `update/3` — owner-only; updates name/description/policy fields.
    * `delete/2` — owner-only; cascades members/invites/blocks.

  ## Membership

    * `join/2` — public group → instant accept; private/secret → join
      request (`accepted_at: nil`).
    * `leave/2` — drops the membership row, decrements counter.
    * `accept_request/3` — admin/owner approves a pending row.
    * `members/1`, `pending_requests/1` — list helpers.

  ## Posts

  Group posts reuse `Angler.Statuses` with a `group_id` FK. `post/3`
  wraps `Statuses.create_local/2` with the group attached and bumps
  `post_count`. The existing favourite/reblog/bookmark pipeline works
  as-is.

  ## Reports / blocks

    * `block/3` — admin/owner bans a profile from the group.
    * `report/4` — files a `group_reports` row; resolved via `resolve_report/3`.
  """

  import Ecto.Query, warn: false

  alias Angler.Groups.{Block, Category, Group, Invite, Member, Report}
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses
  alias Angler.Statuses.Status

  @doc "Whether the operator has enabled the groups feature."
  def enabled?, do: Application.get_env(:angler, :groups_enabled, false) == true

  ## Categories

  @spec list_categories() :: [Category.t()]
  def list_categories do
    Repo.all(from c in Category, order_by: [asc: c.order, asc: c.name])
  end

  @spec ensure_category!(map()) :: Category.t()
  def ensure_category!(%{name: name} = attrs) do
    slug = attrs[:slug] || slugify(name)

    case Repo.get_by(Category, slug: slug) do
      nil ->
        {:ok, c} =
          %Category{}
          |> Category.changeset(Map.put(attrs, :slug, slug))
          |> Repo.insert()

        c

      c ->
        c
    end
  end

  ## Lifecycle

  @spec create(Profile.t(), map()) :: {:ok, Group.t()} | {:error, term()}
  def create(%Profile{} = owner, attrs) when is_map(attrs) do
    name = attrs["name"] || attrs[:name]

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, :name_required}

      true ->
        slug = derive_unique_slug(name)
        normalized = normalize_attrs(attrs, owner, slug)

        Repo.transaction(fn ->
          {:ok, group} = %Group{} |> Group.changeset(normalized) |> Repo.insert()
          {:ok, _} = add_owner_membership(group, owner)
          group
        end)
    end
  end

  defp derive_unique_slug(name) do
    base = slugify(name)

    case Repo.get_by(Group, slug: base) do
      nil ->
        base

      _ ->
        suffix = :crypto.strong_rand_bytes(3) |> Base.url_encode64(padding: false)
        base <> "-" <> suffix
    end
  end

  defp normalize_attrs(attrs, owner, slug) do
    %{
      "name" => attrs["name"] || attrs[:name],
      "slug" => slug,
      "description" => attrs["description"] || attrs[:description],
      "owner_profile_id" => owner.id,
      "category_id" => parse_id_or_nil(attrs["category_id"] || attrs[:category_id]),
      "privacy" => coerce_privacy(attrs["privacy"] || attrs[:privacy]),
      "post_policy" => coerce_policy(attrs["post_policy"] || attrs[:post_policy]),
      "comment_policy" => coerce_policy(attrs["comment_policy"] || attrs[:comment_policy])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp coerce_privacy(p) when p in ["public", "private", "secret"], do: p
  defp coerce_privacy(_), do: "public"

  defp coerce_policy(p) when p in ["members", "admins"], do: p
  defp coerce_policy(_), do: "members"

  defp add_owner_membership(group, owner) do
    %{
      group_id: group.id,
      profile_id: owner.id,
      role: "owner",
      accepted_at: DateTime.utc_now()
    }
    |> Member.changeset()
    |> Repo.insert()
  end

  @spec get(integer() | String.t()) :: Group.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Group, id)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> Repo.get(Group, n) || get_by_slug(id)
      _ -> get_by_slug(id)
    end
  end

  def get(_), do: nil

  @spec get_by_slug(String.t()) :: Group.t() | nil
  def get_by_slug(slug), do: Repo.get_by(Group, slug: String.downcase(slug))

  @spec update(Profile.t(), Group.t(), map()) :: {:ok, Group.t()} | {:error, atom()}
  def update(%Profile{} = actor, %Group{} = group, attrs) do
    if can_admin?(actor, group) do
      group |> Group.changeset(attrs) |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @spec delete(Profile.t(), Group.t()) :: :ok | {:error, atom()}
  def delete(%Profile{id: pid}, %Group{owner_profile_id: pid} = group) do
    Repo.delete!(group)
    :ok
  end

  def delete(_, _), do: {:error, :forbidden}

  ## Membership

  @spec join(Profile.t(), Group.t()) ::
          {:ok, :member, Member.t()}
          | {:ok, :pending, Member.t()}
          | {:error, atom()}
  def join(%Profile{} = profile, %Group{} = group) do
    cond do
      blocked?(group, profile) ->
        {:error, :blocked}

      already_member?(group, profile) ->
        {:error, :already_member}

      true ->
        case existing_invite(group, profile) do
          %Invite{} = inv -> accept_via_invite(group, profile, inv)
          nil -> insert_membership(group, profile)
        end
    end
  end

  defp insert_membership(%Group{privacy: "public"} = g, profile),
    do: insert_membership(g, profile, accept: true)

  defp insert_membership(%Group{} = g, profile),
    do: insert_membership(g, profile, accept: false)

  defp insert_membership(%Group{} = group, %Profile{} = profile, accept: accept?) do
    {state, accepted_at} =
      if accept?, do: {:member, DateTime.utc_now()}, else: {:pending, nil}

    Repo.transaction(fn ->
      {:ok, m} =
        %{
          group_id: group.id,
          profile_id: profile.id,
          role: "member",
          accepted_at: accepted_at
        }
        |> Member.changeset()
        |> Repo.insert()

      if accept? do
        from(g in Group, where: g.id == ^group.id)
        |> Repo.update_all(inc: [member_count: 1])
      end

      {state, m}
    end)
    |> case do
      {:ok, {state, m}} -> {:ok, state, m}
      err -> err
    end
  end

  defp accept_via_invite(group, profile, %Invite{} = inv) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      {:ok, m} =
        %{
          group_id: group.id,
          profile_id: profile.id,
          role: "member",
          accepted_at: now
        }
        |> Member.changeset()
        |> Repo.insert()

      inv |> Ecto.Changeset.change(accepted_at: now) |> Repo.update!()

      from(g in Group, where: g.id == ^group.id)
      |> Repo.update_all(inc: [member_count: 1])

      {:member, m}
    end)
    |> case do
      {:ok, {state, m}} -> {:ok, state, m}
      err -> err
    end
  end

  @spec leave(Profile.t(), Group.t()) :: :ok | {:error, atom()}
  def leave(%Profile{id: pid}, %Group{owner_profile_id: pid}),
    do: {:error, :owner_cannot_leave}

  def leave(%Profile{} = profile, %Group{} = group) do
    case Repo.get_by(Member, group_id: group.id, profile_id: profile.id) do
      nil ->
        {:error, :not_a_member}

      %Member{accepted_at: nil} = m ->
        Repo.delete!(m)
        :ok

      %Member{} = m ->
        Repo.transaction(fn ->
          Repo.delete!(m)

          from(g in Group, where: g.id == ^group.id)
          |> Repo.update_all(inc: [member_count: -1])
        end)

        :ok
    end
  end

  @spec accept_request(Profile.t(), Group.t(), integer()) ::
          {:ok, Member.t()} | {:error, atom()}
  def accept_request(%Profile{} = actor, %Group{} = group, target_profile_id) do
    cond do
      not can_admin?(actor, group) ->
        {:error, :forbidden}

      true ->
        case Repo.get_by(Member, group_id: group.id, profile_id: target_profile_id) do
          nil ->
            {:error, :not_found}

          %Member{accepted_at: %DateTime{}} = m ->
            {:ok, m}

          %Member{} = m ->
            Repo.transaction(fn ->
              updated =
                m
                |> Ecto.Changeset.change(accepted_at: DateTime.utc_now())
                |> Repo.update!()

              from(g in Group, where: g.id == ^group.id)
              |> Repo.update_all(inc: [member_count: 1])

              updated
            end)
        end
    end
  end

  @spec members(Group.t(), keyword()) :: [Member.t()]
  def members(%Group{id: gid}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 40)
    role_filter = Keyword.get(opts, :role)

    base =
      from m in Member,
        where: m.group_id == ^gid and not is_nil(m.accepted_at),
        order_by: [asc: m.role, asc: m.id],
        limit: ^limit,
        preload: :profile

    base =
      case role_filter do
        nil -> base
        r when is_binary(r) -> from m in base, where: m.role == ^r
      end

    Repo.all(base)
  end

  @spec pending_requests(Group.t(), pos_integer()) :: [Member.t()]
  def pending_requests(%Group{id: gid}, limit \\ 40) do
    Repo.all(
      from m in Member,
        where: m.group_id == ^gid and is_nil(m.accepted_at),
        order_by: [desc: m.id],
        limit: ^limit,
        preload: :profile
    )
  end

  @spec member?(Group.t(), Profile.t() | integer()) :: boolean()
  def member?(%Group{id: gid}, %Profile{id: pid}), do: member?(gid, pid)
  def member?(%Group{id: gid}, pid) when is_integer(pid), do: member?(gid, pid)

  def member?(group_id, profile_id) when is_integer(group_id) and is_integer(profile_id) do
    Repo.exists?(
      from m in Member,
        where:
          m.group_id == ^group_id and m.profile_id == ^profile_id and
            not is_nil(m.accepted_at)
    )
  end

  defp can_admin?(%Profile{id: pid}, %Group{id: gid}) do
    Repo.exists?(
      from m in Member,
        where:
          m.group_id == ^gid and m.profile_id == ^pid and
            not is_nil(m.accepted_at) and m.role in ["owner", "admin"]
    )
  end

  defp already_member?(%Group{id: gid}, %Profile{id: pid}),
    do: Repo.exists?(from m in Member, where: m.group_id == ^gid and m.profile_id == ^pid)

  defp existing_invite(%Group{id: gid}, %Profile{id: pid}) do
    Repo.one(
      from i in Invite,
        where:
          i.group_id == ^gid and i.profile_id == ^pid and
            is_nil(i.accepted_at) and is_nil(i.declined_at),
        limit: 1
    )
  end

  ## Invitations

  @spec invite(Profile.t(), Group.t(), integer()) :: {:ok, Invite.t()} | {:error, atom()}
  def invite(%Profile{} = actor, %Group{} = group, target_profile_id) do
    cond do
      not can_admin?(actor, group) ->
        {:error, :forbidden}

      true ->
        case %{
               group_id: group.id,
               profile_id: target_profile_id,
               inviter_profile_id: actor.id
             }
             |> Invite.changeset()
             |> Repo.insert(on_conflict: :nothing) do
          {:ok, %Invite{id: nil}} ->
            {:ok, Repo.get_by!(Invite, group_id: group.id, profile_id: target_profile_id)}

          {:ok, inv} ->
            {:ok, inv}

          err ->
            err
        end
    end
  end

  @spec decline_invite(Profile.t(), Group.t()) :: :ok | {:error, atom()}
  def decline_invite(%Profile{id: pid}, %Group{id: gid}) do
    case Repo.get_by(Invite, group_id: gid, profile_id: pid) do
      nil ->
        {:error, :not_found}

      %Invite{} = inv ->
        inv
        |> Ecto.Changeset.change(declined_at: DateTime.utc_now())
        |> Repo.update!()

        :ok
    end
  end

  @spec invite_check(Profile.t(), Group.t()) :: :ok | :pending | {:error, atom()}
  def invite_check(%Profile{id: pid}, %Group{id: gid}) do
    case Repo.one(
           from i in Invite,
             where:
               i.group_id == ^gid and i.profile_id == ^pid and
                 is_nil(i.accepted_at) and is_nil(i.declined_at),
             limit: 1
         ) do
      nil -> {:error, :not_found}
      %Invite{} -> :pending
    end
  end

  ## Blocks

  @spec block(Profile.t(), Group.t(), integer(), String.t() | nil) ::
          {:ok, Block.t()} | {:error, atom()}
  def block(%Profile{} = actor, %Group{} = group, target_profile_id, reason \\ nil) do
    if can_admin?(actor, group) do
      attrs = %{group_id: group.id, profile_id: target_profile_id, reason: reason}

      case %Block{} |> Block.changeset(attrs) |> Repo.insert(on_conflict: :nothing) do
        {:ok, %Block{id: nil}} ->
          {:ok, Repo.get_by!(Block, group_id: group.id, profile_id: target_profile_id)}

        {:ok, b} ->
          # If the target was already a member, drop the membership.
          from(m in Member,
            where: m.group_id == ^group.id and m.profile_id == ^target_profile_id
          )
          |> Repo.delete_all()

          {:ok, b}

        err ->
          err
      end
    else
      {:error, :forbidden}
    end
  end

  @spec unblock(Profile.t(), Group.t(), integer()) :: :ok | {:error, atom()}
  def unblock(%Profile{} = actor, %Group{} = group, target_profile_id) do
    if can_admin?(actor, group) do
      from(b in Block,
        where: b.group_id == ^group.id and b.profile_id == ^target_profile_id
      )
      |> Repo.delete_all()

      :ok
    else
      {:error, :forbidden}
    end
  end

  @spec list_blocks(Group.t(), pos_integer()) :: [Block.t()]
  def list_blocks(%Group{id: gid}, limit \\ 40) do
    Repo.all(
      from b in Block,
        where: b.group_id == ^gid,
        order_by: [desc: b.id],
        limit: ^limit,
        preload: :profile
    )
  end

  defp blocked?(%Group{id: gid}, %Profile{id: pid}),
    do: Repo.exists?(from b in Block, where: b.group_id == ^gid and b.profile_id == ^pid)

  ## Posts

  @spec post(Profile.t(), Group.t(), map()) :: {:ok, Status.t()} | {:error, atom()}
  def post(%Profile{} = author, %Group{} = group, attrs) do
    cond do
      blocked?(group, author) ->
        {:error, :blocked}

      not can_post?(author, group) ->
        {:error, :forbidden}

      true ->
        case Statuses.create_local(author, Map.put(attrs, "group_id", group.id)) do
          {:ok, status} ->
            from(g in Group, where: g.id == ^group.id)
            |> Repo.update_all(inc: [post_count: 1])

            {:ok, status}

          other ->
            other
        end
    end
  end

  defp can_post?(%Profile{} = author, %Group{post_policy: "admins"} = group),
    do: can_admin?(author, group)

  defp can_post?(%Profile{} = author, %Group{} = group), do: member?(group, author)

  @spec delete_post(Profile.t(), Group.t(), integer()) :: :ok | {:error, atom()}
  def delete_post(%Profile{id: pid} = actor, %Group{} = group, status_id) do
    case Repo.get(Status, status_id) do
      nil ->
        {:error, :not_found}

      %Status{group_id: nil} ->
        {:error, :not_in_group}

      %Status{group_id: gid} when gid != group.id ->
        {:error, :not_in_group}

      %Status{profile_id: ^pid} = status ->
        soft_delete_status!(status, group)
        :ok

      %Status{} = status ->
        if can_admin?(actor, group) do
          soft_delete_status!(status, group)
          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  defp soft_delete_status!(%Status{} = status, %Group{} = group) do
    Repo.transaction(fn ->
      status
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      from(g in Group, where: g.id == ^group.id)
      |> Repo.update_all(inc: [post_count: -1])
    end)
  end

  @spec feed(Group.t(), integer() | nil, pos_integer()) :: [Status.t()]
  def feed(%Group{id: gid}, _viewer_id, limit \\ 30) do
    Repo.all(
      from s in Status,
        where: s.group_id == ^gid and is_nil(s.deleted_at),
        order_by: [desc: s.id],
        limit: ^limit
    )
    |> Repo.preload([
      :profile,
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    ])
  end

  @spec self_feed(Profile.t(), pos_integer()) :: [Status.t()]
  def self_feed(%Profile{id: pid}, limit \\ 30) do
    Repo.all(
      from s in Status,
        join: m in Member,
        on:
          m.group_id == s.group_id and m.profile_id == ^pid and
            not is_nil(m.accepted_at),
        where: not is_nil(s.group_id) and is_nil(s.deleted_at),
        order_by: [desc: s.id],
        limit: ^limit
    )
    |> Repo.preload([
      :profile,
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    ])
  end

  ## Discovery

  @spec popular(pos_integer()) :: [Group.t()]
  def popular(limit \\ 20) do
    Repo.all(
      from g in Group,
        where: g.discoverable == true and g.privacy == "public",
        order_by: [desc: g.member_count, desc: g.id],
        limit: ^limit
    )
  end

  @spec recent(pos_integer()) :: [Group.t()]
  def recent(limit \\ 20) do
    Repo.all(
      from g in Group,
        where: g.discoverable == true and g.privacy == "public",
        order_by: [desc: g.id],
        limit: ^limit
    )
  end

  @spec search(String.t(), pos_integer()) :: [Group.t()]
  def search(q, limit \\ 20) when is_binary(q) do
    if String.trim(q) == "" do
      []
    else
      pattern = "%" <> escape_like(q) <> "%"

      Repo.all(
        from g in Group,
          where:
            g.discoverable == true and g.privacy == "public" and
              ilike(g.name, ^pattern),
          order_by: [desc: g.member_count],
          limit: ^limit
      )
    end
  end

  @spec list_for_profile(Profile.t(), pos_integer()) :: [Group.t()]
  def list_for_profile(%Profile{id: pid}, limit \\ 40) do
    Repo.all(
      from g in Group,
        join: m in Member,
        on:
          m.group_id == g.id and m.profile_id == ^pid and
            not is_nil(m.accepted_at),
        order_by: [desc: m.id],
        limit: ^limit
    )
  end

  ## Reports

  @spec report(Profile.t(), Group.t(), map()) :: {:ok, Report.t()} | {:error, atom()}
  def report(%Profile{} = reporter, %Group{} = group, attrs) do
    %{
      group_id: group.id,
      reporter_profile_id: reporter.id,
      object_type: attrs["object_type"] || attrs[:object_type],
      object_id: parse_id_or_nil(attrs["object_id"] || attrs[:object_id]),
      report_type: attrs["report_type"] || attrs[:report_type],
      message: attrs["message"] || attrs[:message]
    }
    |> Report.changeset()
    |> Repo.insert()
    |> case do
      {:ok, r} -> {:ok, r}
      {:error, _} = err -> err
    end
  end

  @spec list_reports(Group.t(), pos_integer()) :: [Report.t()]
  def list_reports(%Group{id: gid}, limit \\ 40) do
    Repo.all(
      from r in Report,
        where: r.group_id == ^gid and is_nil(r.resolved_at),
        order_by: [desc: r.id],
        limit: ^limit
    )
  end

  @spec resolve_report(Profile.t(), Group.t(), integer()) ::
          {:ok, Report.t()} | {:error, atom()}
  def resolve_report(%Profile{} = actor, %Group{} = group, report_id) do
    if can_admin?(actor, group) do
      case Repo.get(Report, report_id) do
        nil ->
          {:error, :not_found}

        %Report{group_id: gid} when gid != group.id ->
          {:error, :not_found}

        %Report{} = r ->
          updated =
            r
            |> Ecto.Changeset.change(resolved_at: DateTime.utc_now())
            |> Repo.update!()

          {:ok, updated}
      end
    else
      {:error, :forbidden}
    end
  end

  ## Internals

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
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

  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
