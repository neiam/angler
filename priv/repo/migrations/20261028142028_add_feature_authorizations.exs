defmodule Angler.Repo.Migrations.AddFeatureAuthorizations do
  @moduledoc """
  FEP-7aa9 featured collections (upstream v0.15): `feature_authorizations`
  are the stamps a local profile issued to remote `FeaturedCollection`s that
  asked to feature it. A revoked row stays as a deny-record for that
  collection. Who may feature you is the `can_feature` account setting.
  """

  use Ecto.Migration

  def change do
    create table(:feature_authorizations, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :actor_id, references(:profiles, on_delete: :delete_all), null: false
      add :collection_url, :string, size: 500, null: false
      add :collection_name, :string, size: 200
      add :request_url, :string, size: 500
      add :state, :string, size: 20, null: false, default: "approved"
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:feature_authorizations, [:profile_id, :collection_url])
    create index(:feature_authorizations, [:actor_id])
  end
end
