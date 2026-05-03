defmodule Angler.Auth.Workers.SendAppCodeEmail do
  @moduledoc """
  Oban worker that sends the in-app registration verification email.

  See `plans/apps_oauth/queues/send_app_code_email.md`.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 5

  alias Angler.Mailer
  alias Angler.Mailer.AppCodeEmail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "code" => code}}) do
    email
    |> AppCodeEmail.build(code)
    |> Mailer.deliver()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Convenience for callers."
  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(email, code) do
    %{"email" => email, "code" => code}
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
