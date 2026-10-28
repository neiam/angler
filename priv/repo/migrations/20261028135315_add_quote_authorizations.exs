defmodule Angler.Repo.Migrations.AddQuoteAuthorizations do
  @moduledoc """
  FEP-044f quote consent (upstream v0.15):

    * `quote_authorizations` — the stamps a local author issued to remote
      quote posts. A revoked row stays as a deny-record for that quote post.
    * `statuses.quote_policy` — the per-post canQuote override, an audience
      bitmask (`Angler.Quotes`); NULL means the author's account default.
  """

  use Ecto.Migration

  def change do
    create table(:quote_authorizations, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :status_id, references(:statuses, on_delete: :delete_all), null: false
      add :actor_id, references(:profiles, on_delete: :delete_all), null: false
      add :quote_url, :string, size: 500, null: false
      add :request_url, :string, size: 500
      add :state, :string, size: 20, null: false, default: "approved"
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:quote_authorizations, [:status_id, :quote_url])
    create index(:quote_authorizations, [:profile_id])
    create index(:quote_authorizations, [:actor_id])

    alter table(:statuses) do
      add :quote_policy, :smallint
    end
  end
end
