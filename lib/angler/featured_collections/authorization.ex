defmodule Angler.FeaturedCollections.Authorization do
  @moduledoc """
  A FEP-7aa9 `FeatureAuthorization` stamp: a local profile's consent to be
  featured in one remote `FeaturedCollection` (`collection_url`, owned by
  `actor`). Served at `/users/:username/stamps/:id`; `"revoked"` rows serve
  410 and keep a repeat request from the same collection refused. Upstream's
  FeatureAuthorization model.
  """

  use Ecto.Schema

  alias Angler.Profiles.Profile

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, autogenerate: false}

  schema "feature_authorizations" do
    belongs_to :profile, Profile
    belongs_to :actor, Profile

    field :collection_url, :string
    field :collection_name, :string
    field :request_url, :string
    field :state, :string, default: "approved"
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
