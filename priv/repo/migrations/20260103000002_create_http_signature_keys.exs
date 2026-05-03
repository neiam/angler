defmodule Angler.Repo.Migrations.CreateHttpSignatureKeys do
  use Ecto.Migration

  def change do
    create table(:http_signature_keys) do
      add :key_id, :text, null: false
      add :owner_url, :text, null: false
      add :public_key_pem, :text, null: false
      add :fetched_at, :utc_datetime_usec, null: false
      add :rotated_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:http_signature_keys, [:key_id])
    create index(:http_signature_keys, [:owner_url])
  end
end
