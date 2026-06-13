defmodule Mix.Tasks.Angler.Accounts.Enable do
  @moduledoc """
  Enable / bootstrap a local user. Clears any blocking status (pending or
  disabled) so the account can log in, and optionally grants roles.

      # activate a user
      mix angler.accounts.enable alice

      # bootstrap the first operator (activate + grant admin)
      mix angler.accounts.enable alice --admin

      # grant moderator
      mix angler.accounts.enable alice --moderator

  Accepts a username or an email. The release-safe equivalent is
  `bin/angler eval 'Angler.Release.enable_user("alice", admin: true)'`.
  """

  use Mix.Task

  alias Angler.Accounts

  @shortdoc "Enable/bootstrap a user (activate + optional roles)"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, switches: [admin: :boolean, moderator: :boolean])

    handle =
      case positional do
        [h] ->
          h

        _ ->
          Mix.raise("Usage: mix angler.accounts.enable <username|email> [--admin] [--moderator]")
      end

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    case Accounts.enable_user(handle, admin: opts[:admin], moderator: opts[:moderator]) do
      {:ok, user} ->
        roles =
          [user.is_admin && "admin", user.is_moderator && "moderator"]
          |> Enum.filter(& &1)

        suffix = if roles == [], do: "", else: " [" <> Enum.join(roles, ", ") <> "]"
        Mix.shell().info("Enabled user ##{user.id} (#{user.email})#{suffix}")

      {:error, :not_found} ->
        Mix.raise("No user found for #{inspect(handle)}")
    end
  end
end
