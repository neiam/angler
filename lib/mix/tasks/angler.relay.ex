defmodule Mix.Tasks.Angler.Relay do
  @moduledoc """
  Manage ActivityPub relay subscriptions (LitePub/Pleroma model).

      mix angler.relay list
      mix angler.relay follow <actor_url>
      mix angler.relay unfollow <actor_url | id>
      mix angler.relay enable <id>
      mix angler.relay disable <id>

  `follow` takes the relay's **actor URL** (e.g. `https://relay.toot.io/actor`);
  the relay's inbox is discovered from its actor document, and a `Follow` of
  that actor (signed by the instance actor) is sent. The relay flips to
  `accepted` once it replies `Accept` to our inbox — that happens
  asynchronously, so `follow` returns as soon as the Follow is delivered.

  The release-safe equivalents run against the **running** node:

      bin/relay follow https://relay.toot.io/actor
      bin/angler rpc 'Angler.Release.relay_follow("https://relay.toot.io/actor")'
  """

  use Mix.Task

  alias Angler.Federation.Relays

  @shortdoc "Manage ActivityPub relay subscriptions"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)
    dispatch(argv)
  end

  defp dispatch(["list"]), do: list()
  defp dispatch(["follow", actor_url]), do: follow(actor_url)
  defp dispatch(["unfollow", id_or_actor]), do: unfollow(id_or_actor)
  defp dispatch(["enable", id]), do: toggle(id, &Relays.enable/1, "enabled")
  defp dispatch(["disable", id]), do: toggle(id, &Relays.disable/1, "disabled")

  defp dispatch(_) do
    Mix.raise(
      "Usage: mix angler.relay {list | follow <actor_url> | unfollow <actor_url|id> | enable <id> | disable <id>}"
    )
  end

  defp list do
    case Relays.list() do
      [] ->
        Mix.shell().info("No relays configured.")

      relays ->
        Enum.each(relays, fn r ->
          Mix.shell().info("##{r.id}\t#{r.state}\t#{r.actor_url}")
        end)
    end
  end

  defp follow(actor_url) do
    case Relays.subscribe(actor_url) do
      {:ok, relay} ->
        flush_outbound()
        Mix.shell().info("Following relay ##{relay.id} #{relay.actor_url} (#{relay.state}).")

      {:error, %Ecto.Changeset{}} ->
        Mix.shell().info("Already following #{actor_url}.")

      {:error, reason} ->
        Mix.raise("Couldn't follow #{actor_url}: #{inspect(reason)}")
    end
  end

  defp unfollow(id_or_actor) do
    case resolve(id_or_actor) do
      nil ->
        Mix.raise("No relay matching #{inspect(id_or_actor)}.")

      relay ->
        :ok = Relays.unsubscribe(relay)
        flush_outbound()
        Mix.shell().info("Unfollowed relay ##{relay.id} #{relay.actor_url}.")
    end
  end

  defp toggle(id, fun, verb) do
    case resolve(id) do
      nil ->
        Mix.raise("No relay matching #{inspect(id)}.")

      relay ->
        {:ok, updated} = fun.(relay)
        flush_outbound()
        Mix.shell().info("Relay ##{updated.id} #{verb} (#{updated.state}).")
    end
  end

  defp resolve(id_or_actor) do
    case Integer.parse(id_or_actor) do
      {id, ""} -> Relays.get(id)
      _ -> Relays.get_by_actor_url(id_or_actor)
    end
  end

  # `mix` exits as soon as `run/1` returns, killing Oban before it delivers the
  # queued Follow/Undo. Drain the outbound queue inline so the activity is
  # actually sent before we exit. (Under a running release this is unnecessary —
  # Oban delivers normally — so the `Angler.Release` path doesn't drain.)
  defp flush_outbound, do: Oban.drain_queue(queue: :federation_outbound)
end
