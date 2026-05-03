defmodule Angler.Snowflake.Type do
  @moduledoc """
  Ecto type that autogenerates a snowflake on insert.

  Use as the primary key on tables whose IDs need to be federation-compatible
  with Pixelfed.

      @primary_key {:id, Angler.Snowflake.Type, autogenerate: true}
      schema "statuses" do
        # ...
      end

  Stored as `bigint`. JSON renders as a string per Mastodon convention; that
  rendering happens in the response layer, not here.
  """

  use Ecto.Type

  @impl true
  def type, do: :id

  @impl true
  def cast(value) when is_integer(value), do: {:ok, value}

  def cast(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  def cast(_), do: :error

  @impl true
  def load(value) when is_integer(value), do: {:ok, value}
  def load(_), do: :error

  @impl true
  def dump(value) when is_integer(value), do: {:ok, value}
  def dump(_), do: :error

  @impl true
  def autogenerate, do: Angler.Snowflake.next()
end
