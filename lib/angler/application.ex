defmodule Angler.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AnglerWeb.Telemetry,
      Angler.Repo,
      {Angler.Snowflake, Application.get_env(:angler, Angler.Snowflake, [])},
      {DNSCluster, query: Application.get_env(:angler, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Angler.PubSub},
      {Oban, Application.fetch_env!(:angler, Oban)},
      # Start to serve requests, typically the last entry
      AnglerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Angler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AnglerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
