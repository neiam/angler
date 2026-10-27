defmodule Angler.Repo.Migrations.AddMessageToReports do
  use Ecto.Migration

  def change do
    # The reporter's own note, as upstream's reports.message.
    alter table(:reports) do
      add :message, :text
    end
  end
end
