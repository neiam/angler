defmodule Angler.Accounts do
  @moduledoc """
  User context. Local users only — federated profiles live under
  `Angler.Profiles` and never have a `User` row.
  """

  import Ecto.Query, warn: false
  alias Angler.Accounts.User
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

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

  @doc """
  Create a fresh local user + profile in one transaction.

  Used by the onboarding endpoint. Caller is responsible for ensuring the
  email/username/password attrs have already been validated for shape;
  `User.registration_changeset` does final-pass validation and returns
  `{:error, changeset}` on rejection.
  """
  @spec register(map()) ::
          {:ok, %{user: User.t(), profile: Profile.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def register(attrs) do
    email = attrs[:email] || attrs["email"]

    if is_binary(email) and Angler.Admin.email_blocked?(email) do
      {:error, :email_domain_blocked}
    else
      do_register(attrs)
    end
  end

  defp do_register(attrs) do
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
            {:ok, user} -> %{user: user, profile: profile}
            {:error, changeset} -> Repo.rollback(changeset)
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
