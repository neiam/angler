defmodule Mix.Tasks.Angler.Accounts.Admin do
  @moduledoc """
  Grant or revoke admin on a local user.

      # grant admin
      mix angler.accounts.admin alice

      # revoke admin
      mix angler.accounts.admin alice --remove

  Accepts a username or an email. The release-safe equivalent is
  `bin/angler eval 'Angler.Release.set_admin("alice")'`
  (pass `false` as the second arg to revoke).
  """

  use Mix.Task

  alias Angler.Accounts

  @shortdoc "Grant/revoke admin on a user"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: [remove: :boolean])

    handle =
      case positional do
        [h] -> h
        _ -> Mix.raise("Usage: mix angler.accounts.admin <username|email> [--remove]")
      end

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    value = not (opts[:remove] || false)

    case Accounts.set_admin_by_handle(handle, value) do
      {:ok, user} ->
        verb = if value, do: "Granted admin to", else: "Revoked admin from"
        Mix.shell().info("#{verb} ##{user.id} (#{user.email})")

      {:error, :not_found} ->
        Mix.raise("No user found for #{inspect(handle)}")

      {:error, reason} ->
        Mix.raise("Failed: #{inspect(reason)}")
    end
  end
end
