defmodule Angler.Repo.Migrations.CreateInstanceSettings do
  use Ecto.Migration

  def change do
    # Singleton row of operator-editable instance metadata. Each column is a
    # runtime override of the matching env config (nil = fall back to env).
    create table(:instance_settings) do
      add :title, :text
      add :short_description, :text
      add :description, :text
      add :contact_email, :text
      add :contact_username, :text
      add :rules, {:array, :text}
      timestamps(type: :utc_datetime_usec)
    end
  end
end
