defmodule Angler.Quotes.Authorization do
  @moduledoc """
  A FEP-044f `QuoteAuthorization` stamp: a local author's consent for one
  remote post (`quote_url`, by `actor`) to quote one of theirs. Served at
  `/users/:username/quote_authorizations/:id`; `"revoked"` rows serve 410
  and keep a repeat request for the same quote post refused.
  """

  use Ecto.Schema

  alias Angler.Profiles.Profile
  alias Angler.Statuses.Status

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, autogenerate: false}

  schema "quote_authorizations" do
    belongs_to :profile, Profile
    belongs_to :status, Status, type: :integer
    belongs_to :actor, Profile

    field :quote_url, :string
    field :request_url, :string
    field :state, :string, default: "approved"
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
