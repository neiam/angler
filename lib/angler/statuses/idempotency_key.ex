defmodule Angler.Statuses.IdempotencyKey do
  @moduledoc "A claimed `Idempotency-Key` for `POST /api/v1/statuses`. See `Angler.Statuses.Idempotency`."

  use Ecto.Schema

  schema "status_idempotency_keys" do
    field :user_id, :id
    field :key_hash, :binary
    field :status_id, :integer
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
