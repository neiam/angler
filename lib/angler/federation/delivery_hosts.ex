defmodule Angler.Federation.DeliveryHosts do
  @moduledoc """
  Per-host outbound delivery health, as upstream `DeliveryHostService`.

  Consecutive failed deliveries (5xx, connection errors, an unresolvable
  host) are counted on the host's `instances` row, creating it if needed.
  Once the count reaches `:failure_threshold` (default 5) the host is marked
  unavailable until `delivery_next_after`, an exponential backoff of 1h, 2h,
  4h... per failure past the threshold, capped at `:max_backoff` (default 7
  days). Deliveries to it are skipped meanwhile. A 2xx clears the state; a
  3xx/4xx answered but did not take the activity, so it is left alone.

  Unlike upstream, failures reported while a host is already backed off are
  not counted: they come from requests that were in flight when it was
  flagged, and would otherwise push the backoff straight to the cap. When the
  backoff expires the next delivery is the probe; if it fails the backoff
  doubles, if it succeeds the host is cleared.

      config :angler, Angler.Federation.DeliveryHosts,
        failure_threshold: 5,
        max_backoff: 604_800

  Tracking never breaks delivery: database errors are logged and ignored.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Angler.Federation.Instance
  alias Angler.Repo

  @base_backoff 3600
  @max_backoff_exponent 16

  @doc "Lowercase host of an inbox URL, or nil."
  @spec domain(String.t() | nil) :: String.t() | nil
  def domain(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  def domain(_), do: nil

  @doc "Whether deliveries to `domain` are currently being skipped."
  @spec unavailable?(String.t()) :: boolean()
  def unavailable?(domain) when is_binary(domain) do
    now = DateTime.utc_now()

    safely(false, fn ->
      Repo.exists?(
        from i in Instance,
          where:
            i.domain == ^String.downcase(domain) and i.delivery_timeout and
              i.delivery_next_after > ^now
      )
    end)
  end

  @doc "Count a failed delivery against `domain`, backing it off past the threshold."
  @spec record_failure(String.t()) :: :ok
  def record_failure(domain) when is_binary(domain) do
    domain = String.downcase(domain)
    now = DateTime.utc_now()

    safely(:ok, fn ->
      {_, rows} =
        Repo.insert_all(
          Instance,
          [%{domain: domain, delivery_failures: 1, inserted_at: now, updated_at: now}],
          conflict_target: :domain,
          on_conflict:
            from(i in Instance,
              where: is_nil(i.delivery_next_after) or i.delivery_next_after <= ^now,
              update: [inc: [delivery_failures: 1], set: [updated_at: ^now]]
            ),
          returning: [:delivery_failures]
        )

      with [%{delivery_failures: failures}] <- rows,
           true <- failures >= threshold() do
        next = DateTime.add(now, backoff(failures - threshold()), :second)

        from(i in Instance, where: i.domain == ^domain)
        |> Repo.update_all(set: [delivery_timeout: true, delivery_next_after: next])
      end

      :ok
    end)
  end

  @doc "A delivery to `domain` succeeded; clear any failure state. No-op for healthy hosts."
  @spec record_success(String.t()) :: :ok
  def record_success(domain) when is_binary(domain) do
    safely(:ok, fn ->
      clear(
        from i in Instance,
          where: i.domain == ^String.downcase(domain) and i.delivery_failures > 0
      )
    end)
  end

  @doc "Clear a host's failure state by hand (admin)."
  @spec reset(String.t()) :: :ok
  def reset(domain) when is_binary(domain) do
    clear(from i in Instance, where: i.domain == ^String.downcase(String.trim(domain)))
  end

  @doc "Hosts with a non-zero failure count, worst first."
  @spec list_failing(pos_integer()) :: [Instance.t()]
  def list_failing(limit \\ 50) do
    Repo.all(
      from i in Instance,
        where: i.delivery_failures > 0,
        order_by: [desc: i.delivery_failures, asc: i.domain],
        limit: ^limit
    )
  end

  @doc "Seconds to wait after `excess` failures past the threshold: 1h doubling, capped."
  @spec backoff(non_neg_integer()) :: pos_integer()
  def backoff(excess) do
    max = max(@base_backoff, config(:max_backoff, 604_800))
    exponent = excess |> max(0) |> min(@max_backoff_exponent)
    min(@base_backoff * Integer.pow(2, exponent), max)
  end

  defp clear(query) do
    Repo.update_all(query,
      set: [delivery_failures: 0, delivery_timeout: false, delivery_next_after: nil]
    )

    :ok
  end

  defp threshold, do: max(1, config(:failure_threshold, 5))

  defp config(key, default) do
    :angler |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  defp safely(fallback, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("delivery host tracking failed: #{Exception.message(e)}")
      fallback
  end
end
