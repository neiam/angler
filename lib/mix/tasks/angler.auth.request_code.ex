defmodule Mix.Tasks.Angler.Auth.RequestCode do
  @moduledoc """
  Issue an in-app registration verification code and send it via email.

      mix angler.auth.request_code alice@example.com

  Useful for:

  * Smoke-testing SMTP credentials end-to-end after configuring `MAIL_DRIVER`
    and `SMTP_*` env vars.
  * Bootstrapping the first user on a fresh instance — call this, then complete
    registration via `POST /api/auth/onboarding`.

  Until the v1.1 `iar` endpoint is implemented, this task is the only path to
  generate a code outside of test fixtures.

  Pass `--print` to print the plaintext code to stdout instead of (or in
  addition to) sending email — handy for local development without SMTP.

      mix angler.auth.request_code alice@example.com --print
  """

  use Mix.Task

  @shortdoc "Issue an in-app registration verification code"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: [print: :boolean, send: :boolean])

    email =
      case positional do
        [email] -> email
        _ -> Mix.raise("Usage: mix angler.auth.request_code <email> [--print] [--no-send]")
      end

    Mix.Task.run("app.start")
    # Mute Ecto SQL chatter so machine-readable output stays clean.
    Logger.configure(level: :warning)

    case Angler.Auth.issue_code(email) do
      {:ok, code, _register} ->
        if Keyword.get(opts, :print, false) do
          # Single, prefixed line for easy `grep "ANGLER_CODE="` parsing.
          Mix.shell().info("ANGLER_CODE=#{code}")
        end

        if Keyword.get(opts, :send, true), do: enqueue_send(email, code)

      {:error, :too_many_attempts} ->
        Mix.raise("Too many attempts for #{email}. Wait or clear the row manually.")

      {:error, %Ecto.Changeset{} = cs} ->
        Mix.raise("Could not issue code: #{inspect(cs.errors)}")
    end
  end

  defp enqueue_send(email, code) do
    case Angler.Auth.Workers.SendAppCodeEmail.enqueue(email, code) do
      {:ok, %Oban.Job{id: id}} ->
        Mix.shell().info("Enqueued send (Oban job ##{id}). Drain workers to deliver.")

      {:error, reason} ->
        Mix.shell().error("Failed to enqueue send: #{inspect(reason)}")
    end
  end
end
