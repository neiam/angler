defmodule Angler.Accounts do
  @moduledoc """
  User context. Local users only — federated profiles live under
  `Angler.Profiles` and never have a `User` row.
  """

  import Ecto.Query, warn: false
  alias Angler.Accounts.PasswordResetToken
  alias Angler.Accounts.User
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  # How long an emailed password-reset link stays valid.
  @reset_token_validity_seconds 60 * 60

  # User/profile `status` for an account awaiting operator approval. Chosen to
  # trip the existing `is_nil(status)` filters in the auth + lookup paths.
  @pending_status "pending"

  @doc "Get a user by email (case-insensitive). Returns nil if missing/deleted."
  @spec get_by_email(String.t()) :: User.t() | nil
  def get_by_email(email) when is_binary(email) do
    Repo.one(from u in User, where: u.email == ^String.downcase(email) and is_nil(u.status))
  end

  @doc """
  Get an active user by id.

  Returns `nil` if the user is missing or has a non-nil `status` (deleted /
  suspended). Used by the bearer-auth plug to resolve a token's `user_id`.
  """
  @spec get_user(integer() | nil) :: User.t() | nil
  def get_user(nil), do: nil

  def get_user(id) when is_integer(id) do
    Repo.one(from u in User, where: u.id == ^id and is_nil(u.status))
  end

  @doc "Whether a username is available for a fresh local profile."
  @spec username_available?(String.t()) :: boolean()
  def username_available?(username) when is_binary(username) do
    is_nil(Profiles.get_local_by_username(username))
  end

  @doc "Grant or revoke admin on a user."
  @spec set_admin(User.t(), boolean()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_admin(%User{} = user, value) when is_boolean(value) do
    user |> Ecto.Changeset.change(is_admin: value) |> Repo.update()
  end

  @doc "Grant/revoke admin by username or email (status-agnostic lookup)."
  @spec set_admin_by_handle(String.t(), boolean()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_admin_by_handle(handle, value) when is_binary(handle) and is_boolean(value) do
    case find_user_any_status(handle) do
      %User{} = user -> set_admin(user, value)
      nil -> {:error, :not_found}
    end
  end

  @doc "Active local admin profiles — for the public about page."
  @spec list_admins() :: [Profile.t()]
  def list_admins do
    Repo.all(
      from u in User,
        join: p in Profile,
        on: p.id == u.profile_id and is_nil(p.status),
        where: u.is_admin == true and is_nil(u.status),
        order_by: [asc: p.username],
        select: p
    )
  end

  @doc "Whether a user is awaiting operator approval."
  @spec pending?(User.t()) :: boolean()
  def pending?(%User{status: @pending_status}), do: true
  def pending?(%User{}), do: false

  @doc "Active local users awaiting approval, oldest first (profile preloaded)."
  @spec list_pending_users() :: [User.t()]
  def list_pending_users do
    Repo.all(
      from u in User,
        where: u.status == @pending_status,
        order_by: [asc: u.inserted_at],
        preload: :profile
    )
  end

  @doc "Profile ids of users awaiting approval, as a MapSet (for admin renders)."
  @spec pending_profile_ids() :: MapSet.t()
  def pending_profile_ids do
    Repo.all(from u in User, where: u.status == @pending_status, select: u.profile_id)
    |> MapSet.new()
  end

  @doc "Look up a user by its profile id, regardless of status (admin use)."
  @spec get_user_by_profile_id(integer()) :: User.t() | nil
  def get_user_by_profile_id(pid) when is_integer(pid) do
    Repo.one(from u in User, where: u.profile_id == ^pid, preload: :profile)
  end

  @doc """
  Approve a pending account: clears the pending `status` on the user and its
  profile so it can log in and become visible. Idempotent for already-active
  users.
  """
  @spec approve_user(User.t()) :: {:ok, User.t()} | {:error, term()}
  def approve_user(%User{status: @pending_status} = user) do
    Repo.transaction(fn ->
      user = user |> Ecto.Changeset.change(status: nil) |> Repo.update!()

      if user.profile_id do
        from(p in Profile, where: p.id == ^user.profile_id and p.status == @pending_status)
        |> Repo.update_all(set: [status: nil])
      end

      user
    end)
  end

  def approve_user(%User{} = user), do: {:ok, user}

  @doc """
  Reject a pending account by deleting the user and its (content-free) profile.
  Only valid while the account is still pending.
  """
  @spec reject_user(User.t()) :: :ok | {:error, :not_pending | term()}
  def reject_user(%User{status: @pending_status} = user) do
    Repo.transaction(fn ->
      Repo.delete!(user)
      if user.profile_id, do: Repo.delete_all(from p in Profile, where: p.id == ^user.profile_id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  def reject_user(%User{}), do: {:error, :not_pending}

  ## Self-service account management

  @doc "Change the account email after verifying the current password."
  @spec change_email(User.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_password | Ecto.Changeset.t()}
  def change_email(%User{} = user, current_password, new_email) when is_binary(new_email) do
    if User.valid_password?(user, current_password || "") do
      user |> User.email_changeset(%{email: new_email}) |> Repo.update()
    else
      {:error, :invalid_password}
    end
  end

  @doc "Temporarily disable the account (reversible by an operator)."
  @spec disable_own_account(User.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_password}
  def disable_own_account(%User{} = user, password) do
    if User.valid_password?(user, password || "") do
      {:ok, set_self_status(user, "disabled")}
    else
      {:error, :invalid_password}
    end
  end

  @doc """
  Permanently delete the account (soft tombstone `status: "delete"` on the user
  and profile). Honors `ACCOUNT_DELETION_ENABLED` and requires the password.
  """
  @spec delete_own_account(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_password | :deletion_disabled}
  def delete_own_account(%User{} = user, password) do
    cond do
      not Application.get_env(:angler, :account_deletion_enabled, true) ->
        {:error, :deletion_disabled}

      not User.valid_password?(user, password || "") ->
        {:error, :invalid_password}

      true ->
        {:ok, set_self_status(user, "delete")}
    end
  end

  defp set_self_status(%User{} = user, status) do
    {:ok, updated} =
      Repo.transaction(fn ->
        u = user |> Ecto.Changeset.change(status: status) |> Repo.update!()

        if user.profile_id do
          from(p in Profile, where: p.id == ^user.profile_id)
          |> Repo.update_all(set: [status: status])
        end

        u
      end)

    updated
  end

  @doc """
  Enable a user by handle (username or email) regardless of current status —
  clears any blocking `status` (pending/disabled) on the user and a pending
  status on its profile, and optionally grants roles. Intended for
  bootstrapping the first operator.

  Options: `:admin` and `:moderator` (booleans) grant the matching role.
  """
  @spec enable_user(String.t(), keyword()) :: {:ok, User.t()} | {:error, :not_found}
  def enable_user(handle, opts \\ []) when is_binary(handle) do
    case find_user_any_status(handle) do
      %User{} = user ->
        changes =
          %{status: nil}
          |> maybe_put(opts[:admin], :is_admin, true)
          |> maybe_put(opts[:moderator], :is_moderator, true)

        Repo.transaction(fn ->
          user = user |> Ecto.Changeset.change(changes) |> Repo.update!()

          if user.profile_id do
            from(p in Profile, where: p.id == ^user.profile_id and p.status == @pending_status)
            |> Repo.update_all(set: [status: nil])
          end

          user
        end)

      nil ->
        {:error, :not_found}
    end
  end

  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, _, _key, _value), do: map

  # Resolve a local user by username or email ignoring status (so pending /
  # disabled accounts are still found, unlike `lookup_by_handle/1`).
  defp find_user_any_status(handle) do
    if String.contains?(handle, "@") do
      Repo.one(from u in User, where: u.email == ^String.downcase(handle))
    else
      username = String.trim_leading(handle, "@")

      Repo.one(
        from u in User,
          join: p in Profile,
          on: p.id == u.profile_id,
          where: p.username == ^username and is_nil(p.domain)
      )
    end
  end

  @doc """
  Authenticate a local user by handle (email or username) + password.

  Returns `{:ok, user}` on success, `:error` otherwise. Runs a dummy password
  check on the no-user path so response timing doesn't leak whether the
  handle exists.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | :error
  def authenticate(handle, password) when is_binary(handle) and is_binary(password) do
    case lookup_by_handle(handle) do
      %User{} = user ->
        if User.valid_password?(user, password), do: {:ok, user}, else: :error

      nil ->
        _ = User.valid_password?(nil, password)
        :error
    end
  end

  def authenticate(_, _), do: :error

  @doc "Resolve an active local user by email or username. Returns nil if missing."
  @spec lookup_by_handle(String.t()) :: User.t() | nil
  def lookup_by_handle(handle) when is_binary(handle) do
    if String.contains?(handle, "@") do
      get_by_email(handle)
    else
      case Profiles.get_local_by_username(handle) do
        %Profile{id: pid} ->
          Repo.one(from u in User, where: u.profile_id == ^pid and is_nil(u.status))

        _ ->
          nil
      end
    end
  end

  def lookup_by_handle(_), do: nil

  ## Password reset (magic link)

  @doc """
  Issue a password-reset token for `email` and enqueue the reset email.

  Always returns `:ok` whether or not the address maps to an active account,
  so the endpoint can't be used to enumerate registered emails.
  """
  @spec deliver_password_reset(String.t()) :: :ok
  def deliver_password_reset(email) when is_binary(email) do
    case get_by_email(email) do
      %User{} = user ->
        {raw, hash} = gen_reset_token()

        %PasswordResetToken{}
        |> Ecto.Changeset.change(token: hash, user_id: user.id)
        |> Repo.insert!()

        url = AnglerWeb.Endpoint.url() <> "/reset-password/" <> raw
        _ = Angler.Auth.Workers.SendPasswordResetEmail.enqueue(user.email, url)
        :ok

      _ ->
        :ok
    end
  end

  def deliver_password_reset(_), do: :ok

  @doc "Resolve the active user for a non-expired reset token, or nil."
  @spec get_user_by_reset_token(String.t()) :: User.t() | nil
  def get_user_by_reset_token(raw) when is_binary(raw) do
    case Base.url_decode64(raw, padding: false) do
      {:ok, bytes} ->
        hash = :crypto.hash(:sha256, bytes)
        cutoff = DateTime.add(DateTime.utc_now(), -@reset_token_validity_seconds, :second)

        Repo.one(
          from t in PasswordResetToken,
            join: u in User,
            on: u.id == t.user_id and is_nil(u.status),
            where: t.token == ^hash and t.inserted_at > ^cutoff,
            select: u
        )

      _ ->
        nil
    end
  end

  def get_user_by_reset_token(_), do: nil

  @doc "Set a new password for `user` and invalidate all of their reset tokens."
  @spec reset_password(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_password(%User{} = user, attrs) do
    Repo.transaction(fn ->
      case user |> User.change_password_changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          Repo.delete_all(from t in PasswordResetToken, where: t.user_id == ^user.id)
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp gen_reset_token do
    raw = :crypto.strong_rand_bytes(32)
    {Base.url_encode64(raw, padding: false), :crypto.hash(:sha256, raw)}
  end

  @doc """
  Create a fresh local user + profile in one transaction.

  Used by the onboarding endpoint. Caller is responsible for ensuring the
  email/username/password attrs have already been validated for shape;
  `User.registration_changeset` does final-pass validation and returns
  `{:error, changeset}` on rejection.
  """
  @spec register(map(), keyword()) ::
          {:ok, %{user: User.t(), profile: Profile.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def register(attrs, opts \\ []) do
    email = attrs[:email] || attrs["email"]

    if is_binary(email) and Angler.Admin.email_blocked?(email) do
      {:error, :email_domain_blocked}
    else
      # Pending unless the caller forces approval or the instance doesn't
      # require it. A pending user/profile carries `status: "pending"`, which
      # the auth + lookup paths already reject (`is_nil(status)`), so the
      # account can't log in, hold a usable token, or be seen until approved.
      approved? = Keyword.get(opts, :approved, not Angler.Instance.approval_required?())
      do_register(attrs, approved?)
    end
  end

  defp do_register(attrs, approved?) do
    Repo.transaction(fn ->
      profile_attrs = %{
        username: attrs[:username] || attrs["username"],
        name: attrs[:name] || attrs["name"]
      }

      case Profiles.create_profile(profile_attrs) do
        {:ok, profile} ->
          user_attrs =
            attrs
            |> normalize()
            |> Map.put(:profile_id, profile.id)
            |> Map.put(:email_verified_at, DateTime.utc_now())

          case %User{} |> User.registration_changeset(user_attrs) |> Repo.insert() do
            {:ok, user} when approved? ->
              %{user: user, profile: profile}

            {:ok, user} ->
              user = user |> Ecto.Changeset.change(status: @pending_status) |> Repo.update!()

              profile =
                profile |> Ecto.Changeset.change(status: @pending_status) |> Repo.update!()

              %{user: user, profile: profile}

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp normalize(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
