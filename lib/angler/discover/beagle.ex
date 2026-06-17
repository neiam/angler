defmodule Angler.Discover.Beagle do
  @moduledoc """
  Client for Pixelfed's central discovery service, `beagle.pixelfed.net`.

  Beagle aggregates trending posts across the fediverse and exposes them at
  `GET /api/v1/discover` (with an `X-Pixelfed-Api: 1` header). The response is
  `{"statuses": [%{"id" => <AS2 object URL>, "domain" => host, "score" => n, ...}]}`.

  We only consume the `id` (and `domain`) of each entry — the actual post is
  re-fetched and mirrored locally by the ingest path so it behaves like any
  other federated status (openable, likeable, real media). See
  `Angler.Discover.Workers.BeagleDiscover`.

  **Opt-in.** Talking to Beagle is an outbound call to a third-party service, so
  it ships disabled. Enable with:

      config :angler, Angler.Discover.Beagle, enabled: true

  (or `BEAGLE_DISCOVER_ENABLED=1` in `runtime.exs`).
  """

  @default_base "https://beagle.pixelfed.net"
  @discover_path "/api/v1/discover"

  @doc "Whether the Beagle integration is enabled (default: false)."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, false) == true

  @doc """
  Fetch the current network-trending list.

  Returns `{:ok, [%{"id" => url, "domain" => host, ...}]}` (the raw Beagle
  `statuses` entries) or `{:error, reason}`. Entries without a usable string
  `id` are dropped.
  """
  @spec fetch_discover() :: {:ok, [map()]} | {:error, term()}
  def fetch_discover do
    url = base_url() <> @discover_path

    req =
      [
        url: url,
        headers: [{"x-pixelfed-api", "1"}, {"accept", "application/json"}],
        max_redirects: 0,
        # No in-request retries: the hourly cron tick is the retry cadence.
        retry: false,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000]
      ]
      |> Keyword.merge(req_overrides())

    case Req.get(req) do
      {:ok, %{status: 200, body: %{"statuses" => statuses}}} when is_list(statuses) ->
        {:ok, Enum.filter(statuses, &valid_entry?/1)}

      {:ok, %{status: 200, body: _}} ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Internals

  defp valid_entry?(%{"id" => id}) when is_binary(id) and id != "", do: true
  defp valid_entry?(_), do: false

  defp base_url, do: config(:url, @default_base)

  defp config(key, default) do
    :angler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  # Lets tests intercept the outbound call via a Req.Test stub, the same hook
  # `Angler.Federation.HTTP` uses.
  defp req_overrides, do: Application.get_env(:angler, :req_options, [])
end
