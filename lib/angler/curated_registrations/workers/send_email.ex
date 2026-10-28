defmodule Angler.CuratedRegistrations.Workers.SendEmail do
  @moduledoc "Oban worker that delivers a curated-registration email (`Angler.Mailer.CuratedRegisterEmail`)."

  use Oban.Worker, queue: :mailers, max_attempts: 5

  alias Angler.Mailer
  alias Angler.Mailer.CuratedRegisterEmail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"to" => to, "subject" => subject, "text" => text}}) do
    case to |> CuratedRegisterEmail.build(subject, text) |> Mailer.deliver() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Queue `{subject, text}` for `to`."
  @spec enqueue(String.t(), {String.t(), String.t()}) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(to, {subject, text}) do
    %{"to" => to, "subject" => subject, "text" => text}
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
