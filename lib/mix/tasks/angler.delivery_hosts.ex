defmodule Mix.Tasks.Angler.DeliveryHosts do
  @moduledoc """
  Show or clear per-host outbound delivery backoff
  (`Angler.Federation.DeliveryHosts`), as upstream's `app:federation`
  delivery health check and `DeliveryHostService::reset`.

      mix angler.delivery_hosts list
      mix angler.delivery_hosts reset <domain>

  Release equivalents: `Angler.Release.delivery_hosts/0` and
  `Angler.Release.delivery_host_reset/1` via `bin/angler rpc`.
  """

  use Mix.Task

  @shortdoc "Show or clear per-host delivery backoff"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    case argv do
      [] -> Angler.Release.delivery_hosts()
      ["list"] -> Angler.Release.delivery_hosts()
      ["reset", domain] -> Angler.Release.delivery_host_reset(domain)
      _ -> Mix.raise("Usage: mix angler.delivery_hosts {list | reset <domain>}")
    end
  end
end
