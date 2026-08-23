defmodule Angler.PromEx do
  @moduledoc """
  Prometheus metrics for angler, served on port 9568 by `Angler.MetricsPlug`.

  ## Why the prefix is `phx` rather than `angler`

  PromEx names metrics `[otp_app, :prom_ex, plugin]` by default, which would
  give `angler_prom_ex_phoenix_http_requests_total` here and a *different*
  name in every other Phoenix app in this fleet — six near-identical apps that
  no single dashboard could describe.

  Every plugin below overrides that to `[:phx, plugin]`, so all six emit
  identical names and the Kubernetes `namespace` label is what tells them
  apart. That is the same shape the Rust services have, where one dashboard is
  cloned per app with nothing changed but the namespace. Two apps sharing a
  namespace would collide; none do.

  ## Grafana upload is off

  PromEx can push its own bundled dashboards to Grafana on boot. That would
  fight `deployment/grafana`, where git is the source of truth and `sync.sh`
  pushes dashboards the other way — an uploaded dashboard would either be
  reverted by the next sync or quietly win over the committed one. Disabled
  explicitly in `config/config.exs` rather than left to the default, because
  this is the kind of thing that gets turned on by a copied config snippet.
  """

  use PromEx, otp_app: :angler

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      # Uptime and build info, so a restart is visible without reading the
      # process metrics.
      {Plugins.Application, metric_prefix: [:phx, :application]},
      # The BEAM itself: run queue, memory by kind, process and port counts.
      # This is most of what is worth knowing about an Elixir app and none of
      # it is visible from the outside.
      {Plugins.Beam, metric_prefix: [:phx, :beam]},
      # `path` is the *route pattern* from the router, not the request path, so
      # the label stays bounded no matter how many distinct URLs are hit.
      {Plugins.Phoenix,
       router: AnglerWeb.Router, endpoint: AnglerWeb.Endpoint, metric_prefix: [:phx, :phoenix]},
      {Plugins.Ecto, repos: [Angler.Repo], metric_prefix: [:phx, :ecto]},
      # Queue depth by state is the one that matters: jobs piling up in
      # `available` means the workers are behind.
      {Plugins.Oban, metric_prefix: [:phx, :oban]}
    ]
  end
end
