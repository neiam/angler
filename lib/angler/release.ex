defmodule Angler.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :angler

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Enable / bootstrap a user without Mix. Clears any blocking status (pending,
  disabled) and optionally grants roles.

      bin/angler eval 'Angler.Release.enable_user("alice")'
      bin/angler eval 'Angler.Release.enable_user("alice", admin: true)'

  Accepts a username or email. Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  def enable_user(handle, opts \\ []) when is_binary(handle) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Angler.Repo, fn _repo ->
        Angler.Accounts.enable_user(handle, opts)
      end)

    case result do
      {:ok, user} ->
        IO.puts("Enabled user ##{user.id} (#{user.email})" <> roles(user))

      {:error, :not_found} ->
        IO.puts("No user found for #{inspect(handle)}")
    end

    result
  end

  @doc """
  Grant or revoke admin without Mix.

      bin/angler eval 'Angler.Release.set_admin("alice")'
      bin/angler eval 'Angler.Release.set_admin("alice", false)'

  Accepts a username or email. Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  def set_admin(handle, value \\ true) when is_binary(handle) and is_boolean(value) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Angler.Repo, fn _repo ->
        Angler.Accounts.set_admin_by_handle(handle, value)
      end)

    case result do
      {:ok, user} ->
        IO.puts(
          "#{if value, do: "Granted", else: "Revoked"} admin for ##{user.id} (#{user.email})"
        )

      {:error, :not_found} ->
        IO.puts("No user found for #{inspect(handle)}")

      {:error, _} = err ->
        IO.puts("Failed: #{inspect(err)}")
    end

    result
  end

  @doc """
  Enqueue remote-media backfill for federated posts mirrored before remote
  attachment ingestion existed.

      bin/angler eval 'Angler.Release.backfill_remote_media()'

  Inserts one Oban job per candidate status; returns the count enqueued.
  """
  def backfill_remote_media do
    load_app()

    {:ok, count, _} =
      Ecto.Migrator.with_repo(Angler.Repo, fn _repo ->
        # Oban isn't running under `with_repo`; insert job rows directly.
        Angler.Media.Workers.RemoteBackfill.enqueue_all_via_repo()
      end)

    IO.puts("Enqueued #{count} media-backfill job(s).")
    count
  end

  @doc """
  Manage ActivityPub relay subscriptions against the **running** release (these
  need Oban + the HTTP client, so use `rpc`, not `eval`):

      bin/angler rpc 'Angler.Release.relay_follow("https://relay.toot.io/actor")'
      bin/angler rpc 'Angler.Release.relay_list()'
      bin/angler rpc 'Angler.Release.relay_unfollow("https://relay.toot.io/actor")'
      bin/angler rpc 'Angler.Release.relay_unfollow(3)'

  Or use the `bin/relay` wrapper: `bin/relay follow https://relay.toot.io/actor`.
  """
  def relay_follow(actor_url) when is_binary(actor_url) do
    case Angler.Federation.Relays.subscribe(actor_url) do
      {:ok, relay} ->
        IO.puts(
          "Following relay ##{relay.id} #{relay.actor_url} (#{relay.state}); Follow queued."
        )

      {:error, %Ecto.Changeset{}} ->
        IO.puts("Already following #{actor_url}.")

      {:error, reason} ->
        IO.puts("Couldn't follow #{actor_url}: #{inspect(reason)}")
    end
  end

  def relay_list do
    case Angler.Federation.Relays.list() do
      [] ->
        IO.puts("No relays configured.")

      relays ->
        Enum.each(relays, fn r -> IO.puts("##{r.id}\t#{r.state}\t#{r.actor_url}") end)
    end
  end

  def relay_unfollow(id_or_actor) do
    case relay_resolve(id_or_actor) do
      nil ->
        IO.puts("No relay matching #{inspect(id_or_actor)}.")

      relay ->
        :ok = Angler.Federation.Relays.unsubscribe(relay)
        IO.puts("Unfollowed relay ##{relay.id} #{relay.actor_url}; Undo queued.")
    end
  end

  def relay_enable(id), do: relay_toggle(id, &Angler.Federation.Relays.enable/1, "enabled")
  def relay_disable(id), do: relay_toggle(id, &Angler.Federation.Relays.disable/1, "disabled")

  defp relay_toggle(id_or_actor, fun, verb) do
    case relay_resolve(id_or_actor) do
      nil ->
        IO.puts("No relay matching #{inspect(id_or_actor)}.")

      relay ->
        {:ok, updated} = fun.(relay)
        IO.puts("Relay ##{updated.id} #{verb} (#{updated.state}).")
    end
  end

  @doc """
  Outbound delivery health (`Angler.Federation.DeliveryHosts`), as upstream's
  `app:federation` delivery check and its `DeliveryHostService::reset`:

      bin/angler rpc 'Angler.Release.delivery_hosts()'
      bin/angler rpc 'Angler.Release.delivery_host_reset("example.com")'
  """
  def delivery_hosts do
    now = DateTime.utc_now()

    case Angler.Federation.DeliveryHosts.list_failing() do
      [] ->
        IO.puts("No hosts with delivery failures.")

      hosts ->
        Enum.each(hosts, fn i ->
          state =
            if (i.delivery_timeout and i.delivery_next_after) &&
                 DateTime.after?(i.delivery_next_after, now),
               do: "skipped until #{DateTime.to_iso8601(i.delivery_next_after)}",
               else: "retrying"

          IO.puts("#{i.domain}\t#{i.delivery_failures} failures\t#{state}")
        end)
    end
  end

  def delivery_host_reset(domain) when is_binary(domain) do
    :ok = Angler.Federation.DeliveryHosts.reset(domain)
    IO.puts("Cleared delivery failures for #{domain}.")
  end

  defp relay_resolve(id) when is_integer(id), do: Angler.Federation.Relays.get(id)

  defp relay_resolve(str) when is_binary(str) do
    case Integer.parse(str) do
      {id, ""} -> Angler.Federation.Relays.get(id)
      _ -> Angler.Federation.Relays.get_by_actor_url(str)
    end
  end

  defp roles(user) do
    [user.is_admin && "admin", user.is_moderator && "moderator"]
    |> Enum.filter(& &1)
    |> case do
      [] -> ""
      list -> " [" <> Enum.join(list, ", ") <> "]"
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
