defmodule Angler.Repo.Migrations.AddInReplyToUriToStatuses do
  use Ecto.Migration

  # A remote reply's `inReplyTo`, kept even when we don't have the parent:
  # it still marks the post as a reply, and links it up if the parent
  # arrives later.
  def change do
    alter table(:statuses) do
      add :in_reply_to_uri, :text
    end

    create index(:statuses, [:in_reply_to_uri], where: "in_reply_to_uri IS NOT NULL")
  end
end
