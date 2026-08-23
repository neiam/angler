defmodule Angler.MetricsPlug do
  @moduledoc """
  Serves `/metrics` on port 9568, separately from the site.

  Not mounted in the endpoint on purpose. The Ingress matches `/` as a prefix,
  so anything in the Phoenix router is reachable from the internet — that is
  how the Rust services ended up serving `/metrics` publicly. A second listener
  on a port the Ingress does not name keeps it to in-cluster scrapers, and the
  scrape annotations on the pod point here rather than at 4000.

  This runs on Bandit, the same server the endpoint uses. PromEx ships its own
  `metrics_server` option which would do the same job, but it is built on
  Plug.Cowboy — using it would mean compiling and running Cowboy alongside
  Bandit for one route.
  """

  use Plug.Builder

  plug PromEx.Plug, prom_ex_module: Angler.PromEx

  # `PromEx.Plug` passes anything that is not /metrics straight through rather
  # than halting, so without this the listener would answer every other path
  # with 200 and an empty body.
  plug :not_found

  defp not_found(conn, _opts), do: send_resp(conn, 404, "")
end
