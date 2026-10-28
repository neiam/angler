defmodule Angler.Discover.Workers.BeagleDiscover do
  @moduledoc """
  Periodically pull Pixelfed's central network-trending feed from Beagle and
  mirror the posts locally so they surface in
  `GET /api/v1.1/discover/posts/network/trending`.

  Flow (mirrors upstream `BeagleService::getDiscoverPosts`):

    1. `Angler.Discover.Beagle.fetch_discover/0` → list of AS2 object URLs.
    2. Drop entries from admin-banned domains.
    3. Fetch + ingest each URL via `Statuses.Federation.fetch_and_ingest/1`
       (signed, idempotent on object id) — producing `local: false` `Status`
       rows that `Angler.Discover.network_trending/2` already serves.

  No-op unless `Angler.Discover.Beagle.enabled?/0`. Scheduled hourly via
  `Oban.Plugins.Cron`; failures are logged, not retried into a storm — the next
  tick re-polls.
  """

  use Oban.Worker, queue: :federation_inbound, max_attempts: 1

  alias Angler.Discover.Beagle
  alias Angler.Federation.Bans
  alias Angler.Statuses.Federation, as: StatusFed

  require Logger

  # Beagle returns a large set; cap how many we mirror per run.
  @max_ingest 40
  @ingest_concurrency 5

  @impl Oban.Worker
  def perform(_job) do
    if Beagle.enabled?(), do: run(), else: :ok
  end

  defp run do
    case Beagle.fetch_discover() do
      {:ok, entries} ->
        {allowed, banned} = Enum.split_with(entries, &(not banned?(&1)))

        results =
          allowed
          |> Enum.take(@max_ingest)
          |> Task.async_stream(&ingest/1,
            max_concurrency: @ingest_concurrency,
            timeout: 20_000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, :ok} -> :ok
            {:ok, {:error, reason}} -> {:error, reason}
            {:exit, reason} -> {:error, {:exit, reason}}
          end)

        failures =
          for({:error, reason} <- results, do: reason)
          |> Enum.frequencies_by(&reason_label/1)

        Logger.info(
          "Beagle discover: #{length(entries)} listed, #{length(banned)} banned, " <>
            "#{Enum.count(results, &(&1 == :ok))} mirrored, " <>
            "#{Enum.sum(Map.values(failures))} failed#{failure_summary(failures)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("Beagle discover fetch failed: #{inspect(reason)}")
        :ok
    end
  end

  defp ingest(%{"id" => url}) do
    case StatusFed.fetch_and_ingest(url) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Beagle ingest skipped #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Group failures by reason for the run summary (`:timeout`, `:bad_status`, ...).
  defp reason_label({:exit, _}), do: "timeout"
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_label(_), do: "other"

  defp failure_summary(f) when map_size(f) == 0, do: ""

  defp failure_summary(f),
    do: " (" <> Enum.map_join(f, ", ", fn {r, n} -> "#{r}: #{n}" end) <> ")"

  defp banned?(%{"domain" => domain}) when is_binary(domain) and domain != "",
    do: Bans.banned?(domain)

  defp banned?(%{"id" => url}) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> Bans.banned?(host)
      _ -> true
    end
  end

  defp banned?(_), do: true
end
