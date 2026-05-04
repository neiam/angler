defmodule Angler.Repo.Migrations.CreateInstanceDomainBlocks do
  use Ecto.Migration

  def change do
    create table(:instance_domain_blocks) do
      add :domain, :string, null: false
      add :severity, :string, null: false, default: "silence"
      add :reject_media, :boolean, null: false, default: false
      add :reject_reports, :boolean, null: false, default: false
      add :public_comment, :text
      add :private_comment, :text
      add :obfuscate, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:instance_domain_blocks, [:domain])

    create table(:email_domain_blocks) do
      add :domain, :string, null: false
      add :allow_with_approval, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_domain_blocks, [:domain])
  end
end
