defmodule Angler.Repo.Migrations.AddRemoteStories do
  @moduledoc """
  Inbound federated stories (upstream StoryFetch / HandlesStories):

    * `stories.remote_url` — a remote story's AS2 id (upstream `object_id`),
      now unique so a redelivered `Add` can't mirror it twice.
    * `statuses.story_id` — the story a story reply or reaction DM answers
      (upstream keeps it in `entities`).
  """

  use Ecto.Migration

  def change do
    create unique_index(:stories, [:remote_url], where: "remote_url IS NOT NULL")

    alter table(:statuses) do
      add :story_id, references(:stories, on_delete: :nilify_all, type: :bigint)
    end

    create index(:statuses, [:story_id], where: "story_id IS NOT NULL")
  end
end
