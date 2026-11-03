defmodule Angler.Federation.Actor do
  @moduledoc """
  Resolve and cache remote ActivityPub actors.

  * `resolve/1` returns a local `Profile` for a remote actor URL, fetching the
    actor doc if we haven't seen them before, and refreshing it in the
    background once it's more than 3 days old.
  * The actor's `icon` and `image` become the avatar and header. They show
    the origin's URL straight away; with `REMOTE_AVATARS` on (the default)
    `Workers.RemoteAvatarFetch` then swaps in a local copy, and only fetches
    again when the actor points at a new image.
  * `public_key_for/1` resolves a sig `keyId` to a PEM, going through the
    `http_signature_keys` cache and falling back to a fresh actor fetch on miss
    (rotation case).

  All outbound HTTP goes through `Angler.Federation.HTTP.fetch/2` so SSRF and
  banned-domain protections apply.
  """

  import Ecto.Query, warn: false

  alias Angler.Federation.{HttpSignatureKey, Instance}
  alias Angler.Federation.HTTP, as: FedHTTP
  alias Angler.Federation.Workers.{ActorRefresh, RemoteAvatarFetch}
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
      %Profile{} = p ->
        if stale?(p), do: ActorRefresh.enqueue(actor_url)
        {:ok, p}

      nil ->
        fetch_and_create(actor_url)
    end
  end

  @stale_after 3 * 86_400

  defp stale?(%Profile{last_fetched_at: nil}), do: true

  defp stale?(%Profile{last_fetched_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) > @stale_after

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
  Like `public_key_for/1`, but only returns the key when it belongs to
  `actor_url` — the inbox's binding between an HTTP signature and the
  activity's claimed `actor`. Without it any server could sign with its own
  key and speak for any actor.
  """
  @spec public_key_for(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def public_key_for(key_id, actor_url) when is_binary(key_id) and is_binary(actor_url) do
    case Repo.get_by(HttpSignatureKey, key_id: key_id) do
      %HttpSignatureKey{owner_url: owner, public_key_pem: pem} ->
        if same_actor?(owner, actor_url), do: {:ok, pem}, else: {:error, :key_actor_mismatch}

      # Uncached: only the actor's own `<actor>#fragment` key resolves, via
      # the actor doc we fetch for it.
      nil ->
        if same_actor?(strip_fragment(key_id), actor_url),
          do: public_key_for(key_id),
          else: {:error, :key_actor_mismatch}
    end
  end

  @doc """
  Whether two actor URLs name the same actor: exact match after normalising
  scheme/host case, a trailing slash and any fragment.
  """
  @spec same_actor?(String.t() | nil, String.t() | nil) :: boolean()
  def same_actor?(a, b) when is_binary(a) and is_binary(b), do: normalize(a) == normalize(b)
  def same_actor?(_, _), do: false

  @doc "Whether `url` is on `actor_url`'s host (case-insensitive)."
  @spec same_host?(String.t() | nil, String.t() | nil) :: boolean()
  def same_host?(url, actor_url) when is_binary(url) and is_binary(actor_url) do
    case {host(url), host(actor_url)} do
      {h, h} when is_binary(h) -> true
      _ -> false
    end
  end

  def same_host?(_, _), do: false

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

      existing = Repo.get_by(Profile, remote_url: actor_url)
      {image_attrs, fetches} = images(existing, attrs.images)

      profile_attrs =
        attrs
        |> Map.delete(:images)
        |> Map.merge(image_attrs)
        |> Map.put(:domain, domain)
        |> Map.put(:remote_url, actor_url)

      result =
        case existing do
          nil -> insert_profile(profile_attrs, attrs)
          %Profile{} -> update_profile(existing, profile_attrs, attrs)
        end

      with {:ok, %Profile{id: id}} <- result, true <- RemoteAvatarFetch.enabled?() do
        Enum.each(fetches, fn {kind, url} -> RemoteAvatarFetch.enqueue(id, kind, url) end)
      end

      result
    end
  end

  # Avatar/header attrs for this fetch, and the downloads to queue. An image
  # we already have (same source URL) is left as it is, so a refresh keeps
  # the local copy; a new one shows the origin's URL until it's downloaded.
  defp images(existing, sources) do
    Enum.reduce(sources, {%{}, []}, fn {kind, url}, {attrs, fetches} ->
      {path_field, source_field} =
        if kind == "avatar",
          do: {:avatar_path, :avatar_remote_url},
          else: {:header_path, :header_remote_url}

      cond do
        not is_nil(url) and not is_nil(existing) and Map.get(existing, source_field) == url ->
          {attrs, fetches}

        is_nil(url) ->
          {Map.merge(attrs, %{path_field => nil, source_field => nil}), fetches}

        true ->
          {Map.merge(attrs, %{path_field => url, source_field => url}), [{kind, url} | fetches]}
      end
    end)
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
      # A key id already bound to another actor is never rebound: an actor doc
      # can't claim someone else's key and swap in its own PEM.
      %HttpSignatureKey{owner_url: other} = existing ->
        if same_actor?(other, owner_url), do: refresh_key!(existing, pem, now), else: :refused

      nil ->
        %HttpSignatureKey{}
        |> HttpSignatureKey.changeset(%{
          key_id: key_id,
          owner_url: owner_url,
          public_key_pem: pem,
          fetched_at: now
        })
        |> Repo.insert!()
    end
  end

  defp refresh_key!(%HttpSignatureKey{public_key_pem: pem} = existing, pem, now) do
    # Same PEM — just bump fetched_at.
    existing |> HttpSignatureKey.changeset(%{fetched_at: now}) |> Repo.update!()
  end

  defp refresh_key!(existing, pem, now) do
    existing
    |> HttpSignatureKey.changeset(%{public_key_pem: pem, fetched_at: now, rotated_at: now})
    |> Repo.update!()
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

  defp parse_actor(doc, actor_url) when is_map(doc) do
    with {:ok, username} <- Map.fetch(doc, "preferredUsername"),
         {:ok, inbox} <- Map.fetch(doc, "inbox"),
         true <- same_host?(doc["id"] || actor_url, actor_url) do
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
        last_fetched_at: DateTime.utc_now(),
        images: %{
          "avatar" => image_url(doc["icon"], actor_url),
          "header" => image_url(doc["image"], actor_url)
        }
      }

      attrs =
        case extract_public_key(doc, actor_url) do
          {:ok, key} -> Map.merge(attrs, %{public_key_pem: key.pem, public_key: key})
          :error -> attrs
        end

      {:ok, attrs}
    else
      _ -> {:error, :bad_actor_doc}
    end
  end

  # An actor `icon` / `image`: an Image object (or a list of them, first
  # wins) whose `url` is a string, a Link, or a list of either. Only http(s).
  defp image_url([first | _], actor_url), do: image_url(first, actor_url)

  defp image_url(%{"url" => url} = img, actor_url) do
    if img["type"] in [nil, "Image"], do: link_href(url, actor_url)
  end

  defp image_url(_, _), do: nil

  defp link_href([first | _], actor_url), do: link_href(first, actor_url)
  defp link_href(%{"href" => href}, actor_url), do: link_href(href, actor_url)

  defp link_href(url, _actor_url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) -> url
      _ -> nil
    end
  end

  defp link_href(_, _), do: nil

  # The key must live on the actor's own host, and when it names an owner,
  # that owner must be the actor (upstream 1905da723).
  defp extract_public_key(
         %{"publicKey" => %{"id" => kid, "publicKeyPem" => pem} = key} = doc,
         actor_url
       )
       when is_binary(kid) and is_binary(pem) do
    owner_ok? =
      case key["owner"] do
        nil -> true
        owner -> same_actor?(owner, doc["id"] || actor_url)
      end

    if same_host?(kid, actor_url) and owner_ok?, do: {:ok, %{key_id: kid, pem: pem}}, else: :error
  end

  defp extract_public_key(_, _), do: :error

  defp strip_fragment(url), do: url |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()

  defp host(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> nil
    end
  end

  defp normalize(url) do
    uri = URI.parse(url)
    path = (uri.path || "") |> String.trim_trailing("/")

    %URI{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: host(url),
        path: path,
        fragment: nil
    }
    |> URI.to_string()
  end
end
