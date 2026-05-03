defmodule Angler.Profiles do
  @moduledoc """
  The Profiles context.

  Pixelfed-compatible profile lookup helpers. Federation-only fields (keys,
  inbox URLs) live on this struct; the user/auth side will live in
  `Angler.Accounts` once that grouping is implemented.
  """

  import Ecto.Query, warn: false
  alias Angler.Repo
  alias Angler.Profiles.Profile

  @doc """
  Return a local profile by exact username, ignoring case (citext).

  Returns `nil` if no matching local profile exists or if the profile has
  been soft-deleted (`status` is set) or is from a remote instance.
  """
  @spec get_local_by_username(String.t()) :: Profile.t() | nil
  def get_local_by_username(username) when is_binary(username) do
    Repo.one(
      from p in Profile,
        where: p.username == ^username and is_nil(p.domain) and is_nil(p.status)
    )
  end

  @doc """
  Insert a profile.

  Local profiles (no `:domain`) get a freshly-generated RSA-2048 keypair so
  they can sign outbound ActivityPub from day one. Remote profiles store the
  public key fetched from the actor doc; the private key stays nil.
  """
  @spec create_profile(map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def create_profile(attrs) do
    attrs = maybe_assign_keypair(attrs)

    %Profile{}
    |> Profile.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_assign_keypair(attrs) do
    domain = attrs[:domain] || attrs["domain"]
    has_pub = attrs[:public_key_pem] || attrs["public_key_pem"]

    cond do
      # Local profile being created from scratch — mint a keypair.
      is_nil(domain) and is_nil(has_pub) ->
        {pub, priv} = Angler.Profiles.Keypair.generate()
        attrs |> Map.put(:public_key_pem, pub) |> Map.put(:private_key_pem, priv)

      true ->
        attrs
    end
  end

  @doc """
  Get an active profile by id (local or remote).

  Returns `nil` if missing or soft-deleted (`status` is set). Used by the
  bearer-auth plug to resolve a token's `profile_id`.
  """
  @spec get_profile(integer() | nil) :: Profile.t() | nil
  def get_profile(nil), do: nil

  def get_profile(id) when is_integer(id) do
    Repo.one(from p in Profile, where: p.id == ^id and is_nil(p.status))
  end

  @doc """
  Public canonical profile URL.

      iex> Angler.Profiles.url(%Profile{username: "alice", domain: nil})
      "https://localhost/@alice"
  """
  @spec url(Profile.t()) :: String.t()
  def url(%Profile{remote_url: remote, domain: domain})
      when is_binary(remote) and is_binary(domain),
      do: remote

  def url(%Profile{username: username}) do
    AnglerWeb.Endpoint.url() <> "/@" <> username
  end

  @doc "ActivityPub `id` for a local profile."
  @spec actor_url(Profile.t()) :: String.t()
  def actor_url(%Profile{remote_url: remote, domain: domain})
      when is_binary(remote) and is_binary(domain),
      do: remote

  def actor_url(%Profile{username: username}) do
    AnglerWeb.Endpoint.url() <> "/users/" <> username
  end
end
