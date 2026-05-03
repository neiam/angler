defmodule Angler.Federation.Actor do
  @moduledoc """
  Resolve and cache remote ActivityPub actors.

  * `resolve/1` returns a local `Profile` for a remote actor URL, fetching the
    actor doc if we haven't seen them before.
  * `public_key_for/1` resolves a sig `keyId` to a PEM, going through the
    `http_signature_keys` cache and falling back to a fresh actor fetch on miss
    (rotation case).

  All outbound HTTP goes through `Angler.Federation.HTTP.fetch/2` so SSRF and
  banned-domain protections apply.
  """

  import Ecto.Query, warn: false

  alias Angler.Federation.{HttpSignatureKey, Instance}
  alias Angler.Federation.HTTP, as: FedHTTP
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @doc """
  Look up (or fetch) a `Profile` for the given remote actor URL.

  Returns `{:ok, profile}` or `{:error, reason}`.
  """
  @spec resolve(String.t()) :: {:ok, Profile.t()} | {:error, atom()}
  def resolve(actor_url) when is_binary(actor_url) do
    case Repo.get_by(Profile, remote_url: actor_url) do
      %Profile{} = p -> {:ok, p}
      nil -> fetch_and_create(actor_url)
    end
  end

  @doc """
  Resolve a `keyId` (typically `<actor_url>#main-key`) to a public-key PEM.

  Tries the cache first, falls back to fetching the owning actor.
  """
  @spec public_key_for(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def public_key_for(key_id) when is_binary(key_id) do
    case Repo.get_by(HttpSignatureKey, key_id: key_id) do
      %HttpSignatureKey{public_key_pem: pem} ->
        {:ok, pem}

      nil ->
        owner = strip_fragment(key_id)

        with {:ok, profile} <- resolve(owner),
             %{public_key_pem: pem} when is_binary(pem) <- profile do
          # We've already cached the key during fetch_and_create.
          {:ok, pem}
        else
          _ -> {:error, :key_not_found}
        end
    end
  end

  @doc """
  Refresh a cached actor (and its key) — used after a signature failure as a
  rotation defence.
  """
  @spec refresh(String.t()) :: {:ok, Profile.t()} | {:error, atom()}
  def refresh(actor_url) when is_binary(actor_url) do
    fetch_and_create(actor_url)
  end

  ## Internals

  defp fetch_and_create(actor_url) do
    with {:ok, doc} <- FedHTTP.fetch(actor_url),
         {:ok, attrs} <- parse_actor(doc, actor_url) do
      uri = URI.parse(actor_url)
      domain = String.downcase(uri.host)

      :ok = ensure_instance(domain)

      profile_attrs =
        attrs
        |> Map.put(:domain, domain)
        |> Map.put(:remote_url, actor_url)

      case Repo.get_by(Profile, remote_url: actor_url) do
        nil -> insert_profile(profile_attrs, attrs)
        %Profile{} = existing -> update_profile(existing, profile_attrs, attrs)
      end
    end
  end

  defp insert_profile(profile_attrs, %{public_key: %{key_id: kid, pem: pem}} = _) do
    Repo.transaction(fn ->
      case Profiles.create_profile(profile_attrs) do
        {:ok, profile} ->
          upsert_key!(kid, profile.remote_url, pem)
          profile

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, profile} -> {:ok, profile}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_profile(profile_attrs, _no_key) do
    case Profiles.create_profile(profile_attrs) do
      {:ok, p} -> {:ok, p}
      err -> err
    end
  end

  defp update_profile(existing, profile_attrs, attrs) do
    case existing
         |> Profile.changeset(profile_attrs)
         |> Repo.update() do
      {:ok, profile} ->
        case attrs do
          %{public_key: %{key_id: kid, pem: pem}} -> upsert_key!(kid, profile.remote_url, pem)
          _ -> :ok
        end

        {:ok, profile}

      err ->
        err
    end
  end

  defp upsert_key!(key_id, owner_url, pem) do
    now = DateTime.utc_now()

    case Repo.get_by(HttpSignatureKey, key_id: key_id) do
      nil ->
        %HttpSignatureKey{}
        |> HttpSignatureKey.changeset(%{
          key_id: key_id,
          owner_url: owner_url,
          public_key_pem: pem,
          fetched_at: now
        })
        |> Repo.insert!()

      %HttpSignatureKey{public_key_pem: ^pem} = existing ->
        # Same PEM — just bump fetched_at.
        existing
        |> HttpSignatureKey.changeset(%{fetched_at: now})
        |> Repo.update!()

      %HttpSignatureKey{} = existing ->
        existing
        |> HttpSignatureKey.changeset(%{
          public_key_pem: pem,
          fetched_at: now,
          rotated_at: now
        })
        |> Repo.update!()
    end
  end

  defp ensure_instance(domain) do
    case Repo.get_by(Instance, domain: domain) do
      nil ->
        Instance.upsert_changeset(%{domain: domain})
        |> Repo.insert(on_conflict: :nothing)

        :ok

      _ ->
        :ok
    end
  end

  defp parse_actor(doc, _actor_url) when is_map(doc) do
    with {:ok, username} <- Map.fetch(doc, "preferredUsername"),
         {:ok, inbox} <- Map.fetch(doc, "inbox") do
      shared_inbox =
        get_in(doc, ["endpoints", "sharedInbox"]) || nil

      attrs = %{
        username: username,
        name: doc["name"],
        bio: doc["summary"],
        bio_text: doc["summary"],
        inbox_url: inbox,
        outbox_url: doc["outbox"],
        shared_inbox_url: shared_inbox,
        followers_url: doc["followers"],
        following_url: doc["following"],
        is_private: doc["manuallyApprovesFollowers"] == true,
        is_bot: doc["type"] == "Service",
        last_fetched_at: DateTime.utc_now()
      }

      attrs =
        case extract_public_key(doc) do
          {:ok, key} -> Map.merge(attrs, %{public_key_pem: key.pem, public_key: key})
          :error -> attrs
        end

      {:ok, attrs}
    else
      _ -> {:error, :bad_actor_doc}
    end
  end

  defp extract_public_key(%{"publicKey" => %{"id" => kid, "publicKeyPem" => pem}})
       when is_binary(kid) and is_binary(pem) do
    {:ok, %{key_id: kid, pem: pem}}
  end

  defp extract_public_key(_), do: :error

  defp strip_fragment(url), do: url |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()
end
