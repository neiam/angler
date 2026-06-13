defmodule Mix.Tasks.Angler.Accounts.Approve do
  @moduledoc """
  List, approve, or reject local accounts awaiting operator approval.

  When `REGISTRATION_APPROVAL_REQUIRED` is on, new signups are created in a
  pending state and cannot log in until approved.

      # list everyone waiting
      mix angler.accounts.approve

      # approve a pending account by username
      mix angler.accounts.approve alice

      # reject (delete) a pending account
      mix angler.accounts.approve alice --reject
  """

  use Mix.Task

  alias Angler.Accounts

  @shortdoc "List/approve/reject accounts pending operator approval"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, switches: [reject: :boolean, list: :boolean])

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    cond do
      positional == [] or opts[:list] -> list_pending()
      opts[:reject] -> reject(hd(positional))
      true -> approve(hd(positional))
    end
  end

  defp list_pending do
    case Accounts.list_pending_users() do
      [] ->
        Mix.shell().info("No accounts are pending approval.")

      users ->
        Mix.shell().info("Pending approval (#{length(users)}):")

        Enum.each(users, fn u ->
          Mix.shell().info("  @#{u.profile.username}\t#{u.email}\t#{u.inserted_at}")
        end)
    end
  end

  defp approve(username) do
    with_pending(username, fn user ->
      case Accounts.approve_user(user) do
        {:ok, _} -> Mix.shell().info("Approved @#{username}.")
        {:error, reason} -> Mix.raise("Could not approve @#{username}: #{inspect(reason)}")
      end
    end)
  end

  defp reject(username) do
    with_pending(username, fn user ->
      case Accounts.reject_user(user) do
        :ok -> Mix.shell().info("Rejected and removed @#{username}.")
        {:error, reason} -> Mix.raise("Could not reject @#{username}: #{inspect(reason)}")
      end
    end)
  end

  # Pending profiles are filtered out of the normal username lookup, so resolve
  # the user from the pending list instead.
  defp with_pending(username, fun) do
    username = String.trim_leading(username, "@")

    case Enum.find(Accounts.list_pending_users(), &(&1.profile.username == username)) do
      nil -> Mix.raise("No pending account found for @#{username}.")
      user -> fun.(user)
    end
  end
end
