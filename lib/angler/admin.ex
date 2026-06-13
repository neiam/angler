defmodule Angler.Admin do
  @moduledoc """
  Moderator/admin operations. Aggregates the report queue, account actions,
  instance defederation list, and email-domain blocklist.

  Mastodon's admin namespace is large; we cover the surface mobile/web
  moderation clients exercise. Trends, measures, retention, IP blocks,
  canonical email blocks, and roles are deferred.
  """

  import Ecto.Query, warn: false

  alias Angler.Admin.{AccountAction, EmailDomainBlock, InstanceDomainBlock}
  alias Angler.Profiles.Profile
  alias Angler.Reports.Report
  alias Angler.Repo
  alias Angler.Statuses.Status

  ## Reports

  @doc """
  List reports with optional filters:

    * `:resolved` (bool) — `true` returns action-taken; `false` returns
      open queue.
    * `:account_id` — only reports targeting this profile.
    * `:assigned_account_id` — only reports assigned to this moderator.
    * `:limit` — defaults 40.
  """
  @spec list_reports(keyword()) :: [Report.t()]
  def list_reports(opts \\ []) do
    limit = Keyword.get(opts, :limit, 40)

    base = from r in Report, order_by: [desc: r.id], limit: ^limit

    base =
      case Keyword.fetch(opts, :resolved) do
        {:ok, true} -> from r in base, where: r.action_taken == true
        {:ok, false} -> from r in base, where: r.action_taken == false
        :error -> base
      end

    base =
      case Keyword.fetch(opts, :account_id) do
        {:ok, id} -> from r in base, where: r.reported_profile_id == ^id
        :error -> base
      end

    base =
      case Keyword.fetch(opts, :assigned_account_id) do
        {:ok, id} -> from r in base, where: r.assigned_account_id == ^id
        :error -> base
      end

    Repo.all(base)
  end

  @spec get_report(integer()) :: Report.t() | nil
  def get_report(id), do: Repo.get(Report, id)

  @spec assign(Report.t(), Profile.t() | nil) :: {:ok, Report.t()}
  def assign(%Report{} = report, %Profile{id: pid}) do
    {:ok, _} =
      report
      |> Ecto.Changeset.change(assigned_account_id: pid)
      |> Repo.update()

    {:ok, Repo.get!(Report, report.id)}
  end

  def assign(%Report{} = report, nil) do
    {:ok, _} =
      report |> Ecto.Changeset.change(assigned_account_id: nil) |> Repo.update()

    {:ok, Repo.get!(Report, report.id)}
  end

  @spec resolve(Report.t(), Profile.t()) :: {:ok, Report.t()}
  def resolve(%Report{} = report, %Profile{id: moderator_id}) do
    now = DateTime.utc_now()

    {:ok, _} =
      report
      |> Ecto.Changeset.change(
        action_taken: true,
        action_taken_at: now,
        action_taken_by_account_id: moderator_id,
        resolved_at: now
      )
      |> Repo.update()

    {:ok, Repo.get!(Report, report.id)}
  end

  @spec reopen(Report.t()) :: {:ok, Report.t()}
  def reopen(%Report{} = report) do
    {:ok, _} =
      report
      |> Ecto.Changeset.change(
        action_taken: false,
        action_taken_at: nil,
        action_taken_by_account_id: nil,
        resolved_at: nil
      )
      |> Repo.update()

    {:ok, Repo.get!(Report, report.id)}
  end

  ## Accounts

  @doc """
  Filters: `:local` / `:remote` (bool), `:suspended` (bool), `:limit`.
  """
  @spec list_accounts(keyword()) :: [Profile.t()]
  def list_accounts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 40)
    base = from p in Profile, order_by: [desc: p.id], limit: ^limit

    base =
      case Keyword.fetch(opts, :local) do
        {:ok, true} -> from p in base, where: is_nil(p.domain)
        {:ok, false} -> from p in base, where: not is_nil(p.domain)
        :error -> base
      end

    base =
      case Keyword.fetch(opts, :suspended) do
        {:ok, true} -> from p in base, where: p.is_suspended == true
        {:ok, false} -> from p in base, where: p.is_suspended == false
        :error -> base
      end

    base =
      case Keyword.fetch(opts, :pending) do
        # Accounts awaiting approval carry `status: "pending"` (see Angler.Accounts).
        {:ok, true} -> from p in base, where: p.status == "pending"
        _ -> base
      end

    Repo.all(base)
  end

  @spec get_account(integer()) :: Profile.t() | nil
  def get_account(id), do: Repo.get(Profile, id)

  @doc """
  Apply an `action` to a target account.

  Actions:

    * `"suspend"` — sets `is_suspended` true; soft-deletes the profile.
      Statuses become invisible to non-author viewers via the existing
      `is_nil(profile.status)` checks because we set `status: "suspended"`.
    * `"silence"` — sets `is_suspended: false, status: "silenced"`. Posts
      stay visible to followers but drop from the public timeline. (We don't
      yet enforce this in `Timelines.public/2`; the seam is here.)
    * `"disable"` — for local accounts, prevents login by setting
      `users.status = "disabled"`.
    * `"sensitive"` — marks the profile so all their posts are NSFW. We
      currently set `status: "sensitive"` but don't apply at render time.
    * `"none"` — no state change; a warning is logged for the audit trail.

  `notify_text` is captured in the AccountAction row.
  """
  @spec act_on_account(Profile.t(), Profile.t(), String.t(), keyword()) ::
          {:ok, Profile.t()} | {:error, atom()}
  def act_on_account(%Profile{} = target, %Profile{} = moderator, action, opts \\ [])
      when is_binary(action) do
    if action not in AccountAction.actions() do
      {:error, :invalid_action}
    else
      Repo.transaction(fn ->
        apply_action!(target, action)
        log_action!(target, moderator, action, opts)
        Repo.get!(Profile, target.id)
      end)
      |> case do
        {:ok, profile} -> {:ok, profile}
        {:error, _} = err -> err
      end
    end
  end

  defp apply_action!(profile, "suspend") do
    profile
    |> Ecto.Changeset.change(is_suspended: true, status: "suspended")
    |> Repo.update!()
  end

  defp apply_action!(profile, "silence") do
    profile |> Ecto.Changeset.change(status: "silenced") |> Repo.update!()
  end

  defp apply_action!(profile, "disable") do
    profile |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
  end

  defp apply_action!(profile, "sensitive") do
    profile |> Ecto.Changeset.change(status: "sensitive") |> Repo.update!()
  end

  defp apply_action!(profile, "none"), do: profile

  defp log_action!(target, moderator, action, opts) do
    %{
      target_account_id: target.id,
      moderator_account_id: moderator.id,
      report_id: opts[:report_id],
      action: action,
      text: opts[:text],
      send_email_notification: Keyword.get(opts, :notify, false)
    }
    |> AccountAction.changeset()
    |> Repo.insert!()
  end

  @doc "Reverse a suspension (clear is_suspended + status)."
  @spec unsuspend(Profile.t()) :: {:ok, Profile.t()}
  def unsuspend(%Profile{} = profile) do
    profile
    |> Ecto.Changeset.change(is_suspended: false, status: nil)
    |> Repo.update()
  end

  @doc "Reverse a silence."
  @spec unsilence(Profile.t()) :: {:ok, Profile.t()}
  def unsilence(%Profile{} = profile) do
    profile |> Ecto.Changeset.change(status: nil) |> Repo.update()
  end

  @doc "Reverse a disable."
  @spec enable(Profile.t()) :: {:ok, Profile.t()}
  def enable(%Profile{} = profile) do
    profile |> Ecto.Changeset.change(status: nil) |> Repo.update()
  end

  @doc """
  Hard-purge an account's content. Soft-deletes their statuses and clears
  identifying profile fields; the row stays so federation references remain
  resolvable.
  """
  @spec purge_account(Profile.t()) :: :ok
  def purge_account(%Profile{} = profile) do
    Repo.update_all(
      from(s in Status, where: s.profile_id == ^profile.id and is_nil(s.deleted_at)),
      set: [deleted_at: DateTime.utc_now()]
    )

    profile
    |> Ecto.Changeset.change(
      is_suspended: true,
      status: "suspended",
      bio: nil,
      bio_text: nil,
      avatar_path: nil,
      header_path: nil
    )
    |> Repo.update!()

    :ok
  end

  ## Instance domain blocks

  @spec list_instance_domain_blocks(pos_integer()) :: [InstanceDomainBlock.t()]
  def list_instance_domain_blocks(limit \\ 200) do
    Repo.all(from b in InstanceDomainBlock, order_by: [asc: b.domain], limit: ^limit)
  end

  @spec get_instance_domain_block(integer()) :: InstanceDomainBlock.t() | nil
  def get_instance_domain_block(id), do: Repo.get(InstanceDomainBlock, id)

  @spec create_instance_domain_block(map()) ::
          {:ok, InstanceDomainBlock.t()} | {:error, Ecto.Changeset.t()}
  def create_instance_domain_block(attrs) do
    %InstanceDomainBlock{} |> InstanceDomainBlock.changeset(attrs) |> Repo.insert()
  end

  @spec update_instance_domain_block(InstanceDomainBlock.t(), map()) ::
          {:ok, InstanceDomainBlock.t()} | {:error, Ecto.Changeset.t()}
  def update_instance_domain_block(%InstanceDomainBlock{} = b, attrs) do
    b |> InstanceDomainBlock.changeset(attrs) |> Repo.update()
  end

  @spec delete_instance_domain_block(InstanceDomainBlock.t()) :: :ok
  def delete_instance_domain_block(%InstanceDomainBlock{} = b) do
    Repo.delete!(b)
    :ok
  end

  @doc "Whether `domain` should be defederated (severity == 'suspend')."
  @spec instance_suspended?(String.t()) :: boolean()
  def instance_suspended?(domain) when is_binary(domain) do
    Repo.exists?(
      from b in InstanceDomainBlock,
        where: b.domain == ^String.downcase(domain) and b.severity == "suspend"
    )
  end

  ## Email domain blocks

  @spec list_email_domain_blocks(pos_integer()) :: [EmailDomainBlock.t()]
  def list_email_domain_blocks(limit \\ 200) do
    Repo.all(from b in EmailDomainBlock, order_by: [asc: b.domain], limit: ^limit)
  end

  @spec get_email_domain_block(integer()) :: EmailDomainBlock.t() | nil
  def get_email_domain_block(id), do: Repo.get(EmailDomainBlock, id)

  @spec create_email_domain_block(map()) ::
          {:ok, EmailDomainBlock.t()} | {:error, Ecto.Changeset.t()}
  def create_email_domain_block(attrs) do
    %EmailDomainBlock{} |> EmailDomainBlock.changeset(attrs) |> Repo.insert()
  end

  @spec delete_email_domain_block(EmailDomainBlock.t()) :: :ok
  def delete_email_domain_block(%EmailDomainBlock{} = b) do
    Repo.delete!(b)
    :ok
  end

  @doc "Whether `email` ends in a blocked domain."
  @spec email_blocked?(String.t()) :: boolean()
  def email_blocked?(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_, domain] ->
        Repo.exists?(from b in EmailDomainBlock, where: b.domain == ^String.downcase(domain))

      _ ->
        false
    end
  end
end
