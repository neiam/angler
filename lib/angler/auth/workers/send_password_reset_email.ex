defmodule Angler.Auth.Workers.SendPasswordResetEmail do
  @moduledoc "Oban worker that sends the password-reset magic-link email."

  use Oban.Worker, queue: :mailers, max_attempts: 5

  alias Angler.Mailer
  alias Angler.Mailer.PasswordResetEmail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "url" => url}}) do
    email
    |> PasswordResetEmail.build(url)
    |> Mailer.deliver()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Convenience for callers."
  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(email, url) do
    %{"email" => email, "url" => url}
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
