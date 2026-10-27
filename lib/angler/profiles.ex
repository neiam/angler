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

  @doc """
  Resolve a profile by `acct` (`username` or `username@domain`). For remote
  acct strings we fall back to the local cache only — federation discovery
  via WebFinger is callable via `Angler.Federation.Webfinger.resolve/1` if
  the caller wants it.
  """
  @spec lookup_acct(String.t()) :: Profile.t() | nil
  def lookup_acct(acct) when is_binary(acct) do
    acct = String.trim_leading(acct, "@")

    case String.split(acct, "@", parts: 2) do
      [username] ->
        get_local_by_username(username)

      [username, domain] ->
        if local_domain?(domain),
          do: get_local_by_username(username),
          else: lookup_remote_acct(username, domain)
    end
  end

  def lookup_acct(_), do: nil

  # `user@<this instance>` is a local account (upstream 52207c0ab); local
  # rows have no domain, so the remote query would never find it.
  defp local_domain?(domain) do
    String.downcase(domain) == AnglerWeb.Endpoint.url() |> URI.parse() |> Map.get(:host)
  end

  defp lookup_remote_acct(username, domain) do
    Repo.one(
      from p in Profile,
        where:
          p.username == ^username and p.domain == ^String.downcase(domain) and
            is_nil(p.status)
    )
  end

  @doc """
  Prefix-search local profiles by username or display name.
  """
  @spec search(String.t(), keyword()) :: [Profile.t()]
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    pattern = String.trim_leading(query, "@") <> "%"

    Repo.all(
      from p in Profile,
        where:
          is_nil(p.status) and
            (ilike(p.username, ^pattern) or ilike(p.name, ^pattern)),
        order_by: [desc: p.followers_count, asc: p.username],
        limit: ^limit
    )
  end

  @doc "ActivityPub `id` for a local profile."
  @spec actor_url(Profile.t()) :: String.t()
  def actor_url(%Profile{remote_url: remote, domain: domain})
      when is_binary(remote) and is_binary(domain),
      do: remote

  def actor_url(%Profile{username: username}) do
    AnglerWeb.Endpoint.url() <> "/users/" <> username
  end

  @doc """
  Update the authenticated user's profile (PATCH /accounts/update_credentials).

  Accepts a string-keyed map of fields. `avatar` and `header` may be a
  `Plug.Upload` (or compatible) — uploaded via `Angler.Media`, then the
  preview path is saved on the profile.
  """
  @spec update_credentials(Profile.t(), map()) ::
          {:ok, Profile.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_credentials(%Profile{domain: nil} = profile, attrs) do
    with {:ok, attrs} <- maybe_upload_avatar(profile, attrs, "avatar", :avatar_path),
         {:ok, attrs} <- maybe_upload_avatar(profile, attrs, "header", :header_path),
         {:ok, updated} <-
           profile |> Profile.update_credentials_changeset(attrs) |> Repo.update() do
      # Announce the change so remote followers refresh their cached actor
      # (avatar/header/name/bio) — otherwise they keep showing the old one.
      Angler.Profiles.Workers.ActorUpdateDeliver.enqueue_for(updated)
      {:ok, updated}
    end
  end

  def update_credentials(_, _), do: {:error, :not_local_profile}

  defp maybe_upload_avatar(profile, attrs, key, target_field) do
    case Map.get(attrs, key) do
      %{path: _, content_type: _} = upload ->
        case Angler.Media.upload(profile, upload) do
          {:ok, asset} ->
            url =
              Angler.Media.Storage.url(asset, :preview) ||
                Angler.Media.Storage.url(asset, :original)

            {:ok, attrs |> Map.delete(key) |> Map.put(Atom.to_string(target_field), url)}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, attrs}
    end
  end
end
