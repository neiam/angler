defmodule Angler.Stories.Workers.StoryFetch do
  @moduledoc """
  Fetches a remote story named by an inbound `Add` (upstream StoryPipeline
  StoryFetch): a GET of the bearcap URL with its token as a bearer, which
  goes through the guarded federation fetcher and never leaves the story's
  host. The document is validated and mirrored, media and all, by
  `Angler.Stories.Federation.ingest/3`.

  Temporary failures, of the document or its media, retry: the origin only serves a story for its first
  20 minutes, so there's no point retrying for long.
  """

  use Oban.Worker,
    queue: :federation_inbound,
    max_attempts: 3,
    unique: [period: 300, fields: [:args]]

  alias Angler.Federation.HTTP
  alias Angler.Stories
  alias Angler.Stories.Federation

  @accept ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams")

  @spec enqueue(String.t(), String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(url, token, actor_url) do
    %{"url" => url, "token" => token, "actor_url" => actor_url}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "token" => token, "actor_url" => actor_url}}) do
    cond do
      not Stories.enabled?() ->
        :ok

      Federation.mirrored?(url) ->
        :ok

      true ->
        case HTTP.fetch(url, bearer: token, accept: @accept) do
          {:ok, doc} ->
            case Federation.ingest(doc, url, actor_url) do
              {:error, reason} -> {:error, reason}
              _ -> :ok
            end

          {:error, reason} ->
            if HTTP.transient_error?(reason), do: {:error, reason}, else: :ok
        end
    end
  end
end
