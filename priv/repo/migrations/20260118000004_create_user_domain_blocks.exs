defmodule Angler.Repo.Migrations.CreateUserDomainBlocks do
  use Ecto.Migration

  def change do
    create table(:user_domain_blocks) do
      add :profile_id, references(:profiles, on_delete: :delete_all, type: :bigint), null: false
      add :domain, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_domain_blocks, [:profile_id, :domain])
  end
end
