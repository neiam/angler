defmodule Angler.Admin.Pixelfed do
  @moduledoc """
  Operator-side context backing the Pixelfed-shape admin namespace at
  `/api/admin/...`. Each public function corresponds 1:1 to a controller
  action and is gated upstream by the `:admin_read` / `:admin_write`
  pipelines (moderator+ for reads, admin for writes).

  Distinct from `Angler.Admin`, which serves the Mastodon-shape admin
  surface at `/api/v1/admin/...`. Both modules touch the same underlying
  data — only the response shapes differ.

  All writes append a row to `mod_logs` for an audit trail.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.User
  alias Angler.Admin.ModLog
  alias Angler.Federation.Instance
  alias Angler.Profiles.Profile
  alias Angler.Reports.Report
  alias Angler.Repo
  alias Angler.Statuses.Status

  @config_keys ~w(federation_enabled open_registration stories_enabled
                  enforce_email_verification autospam_enabled)

  # Users and instances lists page by this many rows; a full page means
  # there may be another.
  @page_size 10

  ## Stats

  @doc "Single-row summary for `GET /admin/stats`."
  @spec summary() :: map()
  def summary do
    Angler.Instance.stats()
    |> Map.merge(%{
      pending_reports: count_pending_reports(),
      autospam_count: 0,
      profile_count: Repo.aggregate(Profile, :count, :id),
      remote_profile_count:
        Repo.aggregate(from(p in Profile, where: not is_nil(p.domain)), :count, :id),
      remote_instance_count: Repo.aggregate(Instance, :count, :id)
    })
  end

  @doc """
  7-day rolling totals for `GET /admin/instance/stats`. Pixelfed shapes
  this as `{users, posts, instances}` each with a `days[]` series plus
  total/min/max/change rollups.
  """
  @spec all_stats() :: map()
  def all_stats do
    days = 1..7
    today = Date.utc_today()

    user_count = fn d ->
      from(u in User, where: fragment("(?)::date", u.inserted_at) == ^d)
      |> Repo.aggregate(:count, :id)
    end

    post_count = fn d ->
      from(s in Status,
        where:
          is_nil(s.uri) and is_nil(s.deleted_at) and
            fragment("(?)::date", s.inserted_at) == ^d
      )
      |> Repo.aggregate(:count, :id)
    end

    instance_count = fn d ->
      from(i in Instance, where: fragment("(?)::date", i.inserted_at) == ^d)
      |> Repo.aggregate(:count, :id)
    end

    build = fn source ->
      list =
        Enum.map(days, fn d ->
          target = Date.add(today, -d)
          label_full = Calendar.strftime(target, "%a")
          label_short = String.slice(label_full, 0, 1)

          %{
            "date" => Calendar.strftime(target, "%b %-d %Y"),
            "label_full" => label_full,
            "label" => label_short,
            "count" => source.(target)
          }
        end)

      %{
        "days" => list,
        "total" => 0,
        "min" => Enum.min_by(list, & &1["count"], fn -> %{"count" => 0} end)["count"],
        "max" => Enum.max_by(list, & &1["count"], fn -> %{"count" => 0} end)["count"],
        "change" => Enum.reduce(list, 0, &(&1["count"] + &2))
      }
    end

    users = build.(user_count)
    posts = build.(post_count)
    instances = build.(instance_count)

    %{
      "cached_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "users" => Map.put(users, "total", Repo.aggregate(User, :count, :id)),
      "posts" =>
        Map.put(
          posts,
          "total",
          Repo.aggregate(from(s in Status, where: is_nil(s.uri)), :count, :id)
        ),
      "instances" => Map.put(instances, "total", Repo.aggregate(Instance, :count, :id))
    }
  end

  ## Mod reports

  @doc "Newest unresolved reports as Pixelfed-shape rendered maps."
  @spec mod_reports(pos_integer()) :: [map()]
  def mod_reports(limit \\ 20) do
    Repo.all(
      from r in Report,
        where: is_nil(r.resolved_at),
        order_by: [desc: r.id],
        limit: ^limit
    )
    |> Enum.map(&render_report/1)
  end

  defp render_report(%Report{} = r) do
    %{
      "id" => Integer.to_string(r.id),
      "type" => r.type,
      "object_id" => r.object_id,
      "object_type" => r.object_type,
      "created_at" => DateTime.to_iso8601(r.inserted_at)
    }
    |> with_reported_by(r)
    |> with_object_payload(r)
  end

  defp with_reported_by(map, %Report{profile_id: nil}), do: map

  defp with_reported_by(map, %Report{profile_id: pid}) do
    case Repo.get(Profile, pid) do
      nil -> map
      p -> Map.put(map, "reported_by_account", AnglerWeb.MastodonAPI.Account.render(p))
    end
  end

  defp with_object_payload(map, %Report{object_type: "user", object_id: pid}) do
    case Repo.get(Profile, pid) do
      nil -> map
      p -> Map.put(map, "account", AnglerWeb.MastodonAPI.Account.render(p))
    end
  end

  defp with_object_payload(map, %Report{object_type: type, object_id: sid})
       when type in ["post", "story"] do
    case Repo.get(Status, sid) |> maybe_preload_status() do
      nil -> map
      %Status{} = s -> Map.put(map, "status", AnglerWeb.MastodonAPI.Status.render(s, nil))
    end
  end

  defp with_object_payload(map, _), do: map

  defp maybe_preload_status(nil), do: nil
  defp maybe_preload_status(s), do: Repo.preload(s, [:profile, media_attachments: []])

  @doc """
  Apply a moderator decision against a report.

  Actions: `"ignore"` (mark as handled), `"cw"` (flip is_nsfw on the
  reported status), `"unlist"` (drop visibility to unlisted).
  """
  @spec handle_mod_report(User.t(), integer() | String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def handle_mod_report(actor, report_id, action) when is_binary(report_id) do
    case Integer.parse(report_id) do
      {n, ""} -> handle_mod_report(actor, n, action)
      _ -> {:error, :invalid_id}
    end
  end

  def handle_mod_report(%User{} = actor, report_id, action)
      when is_integer(report_id) and action in ["ignore", "cw", "unlist"] do
    case Repo.get(Report, report_id) do
      nil ->
        {:error, :not_found}

      %Report{} = r ->
        Repo.transaction(fn ->
          apply_report_action!(r, action)

          r
          |> Ecto.Changeset.change(
            resolved_at: DateTime.utc_now(),
            action_taken: action != "ignore",
            action_taken_at: DateTime.utc_now(),
            action_taken_by_account_id: actor.profile_id,
            moderator_comment: action
          )
          |> Repo.update!()

          log!(actor, "report.handle", "report", r.id, %{"action" => action})
          %{"success" => true}
        end)
    end
  end

  def handle_mod_report(_, _, _), do: {:error, :invalid_action}

  defp apply_report_action!(_, "ignore"), do: :ok

  defp apply_report_action!(%Report{object_id: sid}, "cw") do
    with %Status{} = s <- Repo.get(Status, sid) do
      s |> Ecto.Changeset.change(is_nsfw: true) |> Repo.update!()
    end
  end

  defp apply_report_action!(%Report{object_id: sid}, "unlist") do
    with %Status{} = s <- Repo.get(Status, sid) do
      s |> Ecto.Changeset.change(visibility: :unlisted) |> Repo.update!()
    end
  end

  ## Autospam — Pixelfed-shape stub
  ##
  ## We don't carry an `account_interstitials` table; ship empty list +
  ## 404 on handle so the admin UI doesn't error out.

  def autospam_list, do: []
  def handle_autospam(_actor, _id, _action), do: {:error, :not_found}

  ## Configuration

  @spec config_list() :: [map()]
  def config_list do
    Enum.map(config_descriptors(), fn %{name: n, key: k, description: d} ->
      %{
        "name" => n,
        "description" => d,
        "key" => k,
        "state" => Angler.Instance.toggle(String.to_atom(k), false)
      }
    end)
  end

  @spec update_config(User.t(), String.t(), term()) ::
          {:ok, [map()]} | {:error, :unknown_key}
  def update_config(%User{} = actor, key, value) when key in @config_keys do
    bool = coerce_bool(value, false)
    {:ok, _} = Angler.Instance.put_toggle(String.to_atom(key), bool)
    log!(actor, "config.update", "config", nil, %{"key" => key, "value" => bool})
    {:ok, config_list()}
  end

  def update_config(_, _, _), do: {:error, :unknown_key}

  defp config_descriptors do
    [
      %{
        name: "ActivityPub Federation",
        key: "federation_enabled",
        description: "Federate with other Pixelfed/Mastodon instances."
      },
      %{
        name: "Open Registration",
        key: "open_registration",
        description: "Allow new account registrations."
      },
      %{
        name: "Stories",
        key: "stories_enabled",
        description: "Enable the ephemeral Stories feature."
      },
      %{
        name: "Require Email Verification",
        key: "enforce_email_verification",
        description: "Require new accounts to verify their email address."
      },
      %{
        name: "AutoSpam Detection",
        key: "autospam_enabled",
        description: "Detect and remove spam from public timelines."
      }
    ]
  end

  ## Users

  @spec users_list(map()) :: %{users: [User.t()], next_max_id: integer() | nil}
  def users_list(opts) do
    sort = if opts["sort"] == "asc", do: :asc, else: :desc

    base = base_users_query(sort)
    base = filter_users_by_query(base, opts["q"])
    base = filter_users_by_max_id(base, opts["max_id"], sort)

    rows = Repo.all(base)
    %{users: rows, next_max_id: next_max_id(rows)}
  end

  defp next_max_id(rows) when length(rows) == @page_size, do: List.last(rows).id
  defp next_max_id(_rows), do: nil

  defp base_users_query(sort) do
    from(u in User,
      where: is_nil(u.status),
      order_by: [{^sort, u.id}],
      limit: @page_size,
      preload: :profile
    )
  end

  defp filter_users_by_query(base, q) when is_binary(q) and q != "" do
    like = "%" <> escape_like(q) <> "%"
    from(u in base, join: p in assoc(u, :profile), where: ilike(p.username, ^like))
  end

  defp filter_users_by_query(base, _), do: base

  # `max_id` is the last row of the previous page: the next page is the
  # rows past it in the sort direction.
  defp filter_users_by_max_id(base, v, sort) do
    case parse_id(v) do
      {:ok, id} -> where(base, ^beyond(sort, dynamic([u], u.id), id))
      :error -> base
    end
  end

  @spec get_user(integer() | String.t()) :: User.t() | nil
  def get_user(id) when is_integer(id),
    do: Repo.get(User, id) |> maybe_preload_user()

  def get_user(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> get_user(n)
      _ -> nil
    end
  end

  def get_user(_), do: nil

  defp maybe_preload_user(nil), do: nil
  defp maybe_preload_user(user), do: Repo.preload(user, :profile)

  @spec user_action(User.t(), integer() | String.t(), String.t(), term()) ::
          {:ok, User.t()} | {:error, atom()}
  def user_action(actor, target_id, action, value \\ nil)

  def user_action(actor, target_id, action, value) when is_binary(target_id) do
    case Integer.parse(target_id) do
      {n, ""} -> user_action(actor, n, action, value)
      _ -> {:error, :invalid_id}
    end
  end

  def user_action(%User{} = actor, target_id, action, value) when is_integer(target_id) do
    case Repo.get(User, target_id) |> Repo.preload(:profile) do
      nil ->
        {:error, :not_found}

      %User{is_admin: true} when action != "refresh_stats" ->
        {:error, :cannot_moderate_admin}

      %User{} = user ->
        do_user_action(actor, user, action, value)
    end
  end

  defp do_user_action(actor, %User{profile: profile} = user, "refresh_stats", _value) do
    followers =
      Repo.aggregate(
        from(f in Angler.Follows.Follower, where: f.profile_id == ^profile.id),
        :count
      )

    following =
      Repo.aggregate(
        from(f in Angler.Follows.Follower, where: f.following_id == ^profile.id),
        :count
      )

    statuses =
      Repo.aggregate(
        from(s in Status, where: s.profile_id == ^profile.id and is_nil(s.deleted_at)),
        :count
      )

    profile
    |> Ecto.Changeset.change(
      followers_count: followers,
      following_count: following,
      statuses_count: statuses
    )
    |> Repo.update!()

    log!(actor, "user.refresh_stats", "user", user.id, %{})
    {:ok, Repo.get!(User, user.id) |> Repo.preload(:profile, force: true)}
  end

  defp do_user_action(actor, user, "verify_email", _value) do
    user
    |> Ecto.Changeset.change(email_verified_at: DateTime.utc_now())
    |> Repo.update!()

    log!(actor, "user.verify_email", "user", user.id, %{})
    {:ok, Repo.get!(User, user.id) |> Repo.preload(:profile)}
  end

  defp do_user_action(actor, user, flag, value) when flag in ~w(unlisted cw no_autolink) do
    profile = user.profile
    new = coerce_bool(value, !Map.get(profile, String.to_atom(flag)))

    profile
    |> Ecto.Changeset.change([{String.to_atom(flag), new}])
    |> Repo.update!()

    log!(actor, "user.#{flag}", "user", user.id, %{"value" => new})
    {:ok, Repo.get!(User, user.id) |> Repo.preload(:profile, force: true)}
  end

  defp do_user_action(actor, user, "delete", _value) do
    if Application.get_env(:angler, :account_deletion_enabled, true) do
      user |> Ecto.Changeset.change(status: "delete") |> Repo.update!()
      user.profile |> Ecto.Changeset.change(status: "delete") |> Repo.update!()
      Angler.Accounts.federate_account_delete(user)
      log!(actor, "user.delete", "user", user.id, %{})
      {:ok, %{user | status: "delete"}}
    else
      {:error, :deletion_disabled}
    end
  end

  defp do_user_action(_, _, _, _), do: {:error, :invalid_action}

  ## Instances

  @spec instances_list(map()) ::
          %{instances: [Instance.t()], next_max_id: integer() | nil}
  def instances_list(opts) do
    sort = if opts["sort"] == "asc", do: :asc, else: :desc
    sort_by = sort_by_key(opts["sort_by"])

    base =
      from(i in Instance,
        order_by: ^[{sort, instance_sort_expr(sort_by)}, {sort, dynamic([i], i.id)}],
        limit: @page_size
      )

    base = filter_instances_by_query(base, opts["q"])
    base = filter_instances_by_flag(base, opts["filter"])
    base = filter_instances_by_max_id(base, opts["max_id"], sort_by, sort)

    rows = Repo.all(base)
    %{instances: rows, next_max_id: next_max_id(rows)}
  end

  defp filter_instances_by_query(base, q) when is_binary(q) and q != "" do
    like = "%" <> escape_like(q) <> "%"
    from(i in base, where: ilike(i.domain, ^like))
  end

  defp filter_instances_by_query(base, _), do: base

  defp filter_instances_by_flag(base, f) when f in ["unlisted", "auto_cw", "banned"] do
    col = String.to_atom(f)
    from(i in base, where: field(i, ^col) == true)
  end

  defp filter_instances_by_flag(base, _), do: base

  # Counts may be unknown; they sort (and compare) as 0.
  defp instance_sort_expr(:id), do: dynamic([i], i.id)
  defp instance_sort_expr(:domain), do: dynamic([i], i.domain)
  defp instance_sort_expr(col), do: dynamic([i], coalesce(field(i, ^col), 0))

  # `max_id` stays a bare id, as Pixelfed clients send it back, so the
  # keyset (sort value, id) is rebuilt from the row it names.
  defp filter_instances_by_max_id(base, v, sort_by, sort) do
    case parse_id(v) do
      {:ok, id} -> where(base, ^instance_keyset(id, sort_by, sort))
      :error -> base
    end
  end

  defp instance_keyset(id, :id, sort), do: beyond(sort, dynamic([i], i.id), id)

  defp instance_keyset(id, sort_by, sort) do
    case Repo.get(Instance, id) do
      # The cursor row is gone; id order is the best remaining guess.
      nil ->
        beyond(sort, dynamic([i], i.id), id)

      %Instance{} = row ->
        value = Map.fetch!(row, sort_by) || 0
        col = instance_sort_expr(sort_by)

        dynamic(
          ^beyond(sort, col, value) or
            (^col == ^value and ^beyond(sort, dynamic([i], i.id), id))
        )
    end
  end

  defp beyond(:asc, expr, value), do: dynamic(^expr > ^value)
  defp beyond(:desc, expr, value), do: dynamic(^expr < ^value)

  @spec get_instance(integer() | String.t()) :: Instance.t() | nil
  def get_instance(id) when is_integer(id), do: Repo.get(Instance, id)

  def get_instance(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> get_instance(n)
      _ -> nil
    end
  end

  def get_instance(_), do: nil

  @spec moderate_instance(User.t(), integer() | String.t(), String.t(), term()) ::
          {:ok, Instance.t()} | {:error, atom()}
  def moderate_instance(%User{} = actor, id, key, value)
      when key in ["unlisted", "auto_cw", "banned"] do
    case get_instance(id) do
      nil ->
        {:error, :not_found}

      %Instance{} = inst ->
        new = coerce_bool(value, false)

        updated =
          inst
          |> Instance.moderation_changeset(%{key => new})
          |> Repo.update!()

        log!(actor, "instance.#{key}", "instance", inst.id, %{"value" => new})
        {:ok, updated}
    end
  end

  def moderate_instance(_, _, _, _), do: {:error, :invalid_key}

  @spec refresh_instance_stats(User.t(), integer() | String.t()) ::
          {:ok, Instance.t()} | {:error, atom()}
  def refresh_instance_stats(%User{} = actor, id) do
    case get_instance(id) do
      nil ->
        {:error, :not_found}

      %Instance{domain: domain} = inst ->
        users = Repo.aggregate(from(p in Profile, where: p.domain == ^domain), :count, :id)

        statuses =
          Repo.aggregate(
            from(s in Status,
              join: p in Profile,
              on: s.profile_id == p.id,
              where: p.domain == ^domain
            ),
            :count
          )

        updated =
          inst
          |> Ecto.Changeset.change(user_count: users, status_count: statuses)
          |> Repo.update!()

        log!(actor, "instance.refresh_stats", "instance", inst.id, %{})
        {:ok, updated}
    end
  end

  ## Post moderation

  ## Posts and profiles (upstream AdminApiController getPosts / getPost /
  ## getProfiles / getProfile / moderateProfile). Paged with an opaque cursor,
  ## as upstream's cursorPaginate: 30 posts or 20 profiles a page.

  @post_filters ~w(all local remote nsfw unlisted private)

  @doc "A page of statuses for the admin post browser."
  @spec posts_list(map()) :: %{statuses: [Status.t()], next_cursor: String.t() | nil}
  def posts_list(params) do
    sort = if params["sort"] == "asc", do: :asc, else: :desc
    filter = if params["filter"] in @post_filters, do: params["filter"], else: "local"
    q = String.trim(to_string(params["q"] || ""))

    base =
      from(s in Status, where: is_nil(s.reblog_of_id) and is_nil(s.deleted_at))
      |> filter_posts(filter)
      |> filter_posts_profile(params["profile_id"])

    case search_posts(base, q) do
      nil ->
        %{statuses: [], next_cursor: nil}

      query ->
        rows =
          query
          |> after_cursor(params["cursor"], sort)
          |> order_by([s], [{^sort, s.id}])
          |> limit(31)
          |> preload([:profile, :mentions, :media_attachments, status_hashtags: :hashtag])
          |> Repo.all()

        page(rows, 30, :statuses)
    end
  end

  defp filter_posts(q, "local"), do: where(q, [s], s.local == true)
  defp filter_posts(q, "remote"), do: where(q, [s], s.local == false)
  defp filter_posts(q, "nsfw"), do: where(q, [s], s.is_nsfw == true)
  defp filter_posts(q, "unlisted"), do: where(q, [s], s.visibility == :unlisted)
  defp filter_posts(q, "private"), do: where(q, [s], s.visibility == :private)
  defp filter_posts(q, _all), do: q

  defp filter_posts_profile(q, id) do
    case parse_id(id) do
      {:ok, pid} -> where(q, [s], s.profile_id == ^pid)
      _ -> q
    end
  end

  # A number is a post id, `@name` a profile, anything else caption text.
  # nil when `@name` matches nobody.
  defp search_posts(q, ""), do: q

  defp search_posts(q, "@" <> username) do
    case Repo.get_by(Profile, username: username) do
      %Profile{id: pid} -> where(q, [s], s.profile_id == ^pid)
      nil -> nil
    end
  end

  defp search_posts(q, text) do
    case Integer.parse(text) do
      {id, ""} -> where(q, [s], s.id == ^id)
      _ -> where(q, [s], ilike(s.caption, ^("%" <> escape_like(text) <> "%")))
    end
  end

  defp after_cursor(q, cursor, sort) do
    case decode_cursor(cursor) do
      [id] when sort == :asc -> where(q, [s], s.id > ^id)
      [id] -> where(q, [s], s.id < ^id)
      _ -> q
    end
  end

  defp page(rows, per_page, key) do
    {items, more} = Enum.split(rows, per_page)
    next = if more != [], do: encode_cursor(List.last(items)), else: nil
    %{key => items, next_cursor: next}
  end

  @doc "The admin view of one status: the status plus moderation facts."
  @spec get_post(term()) :: {Status.t(), map()} | nil
  def get_post(id) do
    with {:ok, sid} <- parse_id(id),
         %Status{} = status <-
           Status
           |> Repo.get(sid)
           |> Repo.preload([:profile, :mentions, :media_attachments, status_hashtags: :hashtag]) do
      profile = status.profile

      reports =
        from(r in Report, where: r.object_type == "post" and r.object_id == ^status.id)

      meta = %{
        "is_local" => status.local,
        "type" => status.type,
        "scope" => status.scope,
        "is_nsfw" => status.is_nsfw,
        "report_count" => Repo.aggregate(reports, :count),
        "open_report_count" =>
          reports |> where([r], is_nil(r.resolved_at)) |> Repo.aggregate(:count),
        "autospam" => false,
        "profile" => %{
          "id" => Integer.to_string(profile.id),
          "username" => profile.username,
          "is_local" => is_nil(profile.domain),
          "user_id" => user_id_string(profile),
          "is_admin" => admin_target?(profile),
          "moderation" => %{
            "unlisted" => profile.unlisted,
            "cw" => profile.cw,
            "no_autolink" => profile.no_autolink
          }
        }
      }

      {status, meta}
    else
      _ -> nil
    end
  end

  @profile_sorts %{
    "id" => :id,
    "followers_count" => :followers_count,
    "status_count" => :statuses_count
  }

  @doc "A page of profiles for the admin profile browser."
  @spec profiles_list(map()) :: %{profiles: [Profile.t()], next_cursor: String.t() | nil}
  def profiles_list(params) do
    sort = if params["sort"] == "asc", do: :asc, else: :desc
    field = Map.get(@profile_sorts, params["sort_by"], :id)
    q = params["q"] |> to_string() |> String.trim() |> String.trim_leading("@")

    base =
      from(p in Profile, where: is_nil(p.status))
      |> then(fn base ->
        case params["filter"] do
          "local" -> where(base, [p], is_nil(p.domain))
          "remote" -> where(base, [p], not is_nil(p.domain))
          _ -> base
        end
      end)
      |> then(fn base ->
        if q == "", do: base, else: where(base, [p], ilike(p.username, ^(escape_like(q) <> "%")))
      end)

    rows =
      base
      |> profile_cursor(params["cursor"], field, sort)
      |> order_by([p], [{^sort, field(p, ^field)}, {^sort, p.id}])
      |> limit(21)
      |> Repo.all()

    {items, more} = Enum.split(rows, 20)

    next =
      case {more, List.last(items)} do
        {[_ | _], %Profile{} = last} -> encode_cursor(last, Map.get(last, field) || 0)
        _ -> nil
      end

    %{profiles: items, next_cursor: next}
  end

  defp profile_cursor(q, cursor, :id, sort) do
    case decode_cursor(cursor) do
      [id] when sort == :asc -> where(q, [p], p.id > ^id)
      [id] -> where(q, [p], p.id < ^id)
      _ -> q
    end
  end

  defp profile_cursor(q, cursor, field, sort) do
    case decode_cursor(cursor) do
      [v, id] when sort == :asc ->
        where(
          q,
          [p],
          coalesce(field(p, ^field), 0) > ^v or
            (coalesce(field(p, ^field), 0) == ^v and p.id > ^id)
        )

      [v, id] ->
        where(
          q,
          [p],
          coalesce(field(p, ^field), 0) < ^v or
            (coalesce(field(p, ^field), 0) == ^v and p.id < ^id)
        )

      _ ->
        q
    end
  end

  defp encode_cursor(%{id: id}), do: [id] |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp encode_cursor(%{id: id}, value),
    do: [value, id] |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp decode_cursor(c) when is_binary(c) do
    with {:ok, json} <- Base.url_decode64(c, padding: false),
         {:ok, list} when is_list(list) <- Jason.decode(json),
         true <- Enum.all?(list, &is_integer/1) do
      list
    else
      _ -> nil
    end
  end

  defp decode_cursor(_), do: nil

  @doc "The admin view of one profile: the profile plus report counts."
  @spec get_profile(term()) :: {Profile.t(), map()} | nil
  def get_profile(id) do
    with {:ok, pid} <- parse_id(id),
         %Profile{} = profile <- Repo.get(Profile, pid) do
      reports = from(r in Report, where: r.reported_profile_id == ^pid)

      {profile,
       %{
         "report_count" => Repo.aggregate(reports, :count),
         "open_report_count" =>
           reports |> where([r], is_nil(r.resolved_at)) |> Repo.aggregate(:count),
         "autospam_count" => 0,
         "is_admin" => admin_target?(profile)
       }}
    else
      _ -> nil
    end
  end

  @doc """
  Set one of a profile's moderation flags (`unlisted`, `cw`, `no_autolink`).
  Admin accounts can't be moderated.
  """
  @spec moderate_profile(User.t(), term(), term(), term()) ::
          {:ok, Profile.t()} | {:error, :not_found | :invalid_key | :cannot_moderate_admin}
  def moderate_profile(%User{} = actor, id, key, value)
      when key in ["unlisted", "cw", "no_autolink"] do
    with {:ok, pid} <- parse_id(id),
         %Profile{} = profile <- Repo.get(Profile, pid),
         false <- admin_target?(profile) && :admin do
      value = coerce_bool(value, false)

      updated =
        profile
        |> Ecto.Changeset.change([{String.to_existing_atom(key), value}])
        |> Repo.update!()

      log!(actor, "profile.#{key}", "profile", pid, %{"value" => value})
      {:ok, updated}
    else
      :admin -> {:error, :cannot_moderate_admin}
      _ -> {:error, :not_found}
    end
  end

  def moderate_profile(_actor, _id, _key, _value), do: {:error, :invalid_key}

  defp user_id_string(%Profile{id: pid}) do
    case Repo.one(from u in User, where: u.profile_id == ^pid, select: u.id) do
      nil -> nil
      uid -> Integer.to_string(uid)
    end
  end

  @spec moderate_post(User.t(), integer() | String.t(), String.t()) ::
          {:ok, Status.t()} | {:error, atom()}
  def moderate_post(%User{} = actor, id, action) do
    with {:ok, sid} <- parse_id(id),
         %Status{} = status <- Repo.get(Status, sid) |> Repo.preload(:profile) do
      if admin_target?(status.profile) do
        {:error, :cannot_moderate_admin}
      else
        do_moderate_post(actor, status, action)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp admin_target?(%Profile{id: pid}) do
    Repo.exists?(from u in User, where: u.profile_id == ^pid and u.is_admin == true)
  end

  defp admin_target?(_), do: false

  defp do_moderate_post(actor, %Status{} = status, "cw") do
    new = !status.is_nsfw
    updated = status |> Ecto.Changeset.change(is_nsfw: new) |> Repo.update!()
    log!(actor, "status.cw", "status", status.id, %{"value" => new})
    {:ok, updated}
  end

  defp do_moderate_post(actor, %Status{} = status, action)
       when action in ~w(mark-public mark-unlisted mark-private) do
    new = visibility_for(action)
    updated = status |> Ecto.Changeset.change(visibility: new) |> Repo.update!()
    log!(actor, "status.#{action}", "status", status.id, %{})
    {:ok, updated}
  end

  defp do_moderate_post(actor, %Status{} = status, "delete") do
    updated =
      status
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

    Angler.Quotes.status_deleted(status.id)
    log!(actor, "status.delete", "status", status.id, %{})
    {:ok, updated}
  end

  defp do_moderate_post(actor, %Status{} = status, "mark-spammer") do
    Repo.transaction(fn ->
      status.profile
      |> Ecto.Changeset.change(unlisted: true, cw: true, no_autolink: true)
      |> Repo.update!()

      from(s in Status,
        where: s.profile_id == ^status.profile_id and is_nil(s.deleted_at)
      )
      |> Repo.update_all(set: [is_nsfw: true, visibility: "private"])

      log!(actor, "status.mark_spammer", "user", status.profile_id, %{})
    end)

    {:ok, Repo.get!(Status, status.id)}
  end

  defp do_moderate_post(_, _, _), do: {:error, :invalid_action}

  defp visibility_for("mark-public"), do: :public
  defp visibility_for("mark-unlisted"), do: :unlisted
  defp visibility_for("mark-private"), do: :private

  ## Mod log writes

  @spec log!(User.t(), String.t(), String.t(), integer() | nil, map()) :: ModLog.t()
  def log!(%User{id: actor_id}, action, object_type, object_id, metadata \\ %{}) do
    %{
      actor_user_id: actor_id,
      action: action,
      object_type: object_type,
      object_id: object_id,
      access_level: "moderator",
      metadata: metadata
    }
    |> ModLog.changeset()
    |> Repo.insert!()
  end

  ## Internals

  defp count_pending_reports do
    Repo.aggregate(from(r in Report, where: is_nil(r.resolved_at)), :count, :id)
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp sort_by_key(k) when k in ["id", "status_count", "user_count", "domain"],
    do: String.to_atom(k)

  defp sort_by_key(_), do: :id

  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp coerce_bool(true, _), do: true
  defp coerce_bool(false, _), do: false
  defp coerce_bool("true", _), do: true
  defp coerce_bool("1", _), do: true
  defp coerce_bool(1, _), do: true
  defp coerce_bool("false", _), do: false
  defp coerce_bool("0", _), do: false
  defp coerce_bool(0, _), do: false
  defp coerce_bool(nil, default), do: default
  defp coerce_bool(_, default), do: default
end
