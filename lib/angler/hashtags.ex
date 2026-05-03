defmodule Angler.Hashtags do
  @moduledoc """
  Hashtag lookup + upsert.

  Names are stored lower-cased. `slug` is currently a copy of `name` —
  Pixelfed strips diacritics and other non-ASCII into a slug; we'll port
  that mapping when search lands.
  """

  import Ecto.Query, warn: false
  alias Angler.Hashtags.Hashtag
  alias Angler.Repo

  @doc "Get a hashtag by name (case-insensitive). Returns nil if missing."
  @spec get_by_name(String.t()) :: Hashtag.t() | nil
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(Hashtag, name: String.downcase(name))
  end

  @doc "Find or create a hashtag by name (case-insensitive)."
  @spec ensure!(String.t()) :: Hashtag.t()
  def ensure!(name) when is_binary(name) do
    name = String.downcase(name)

    case Repo.get_by(Hashtag, name: name) do
      %Hashtag{} = tag ->
        tag

      nil ->
        %{name: name, slug: name}
        |> Hashtag.changeset()
        |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
        |> case do
          {:ok, %Hashtag{id: id}} when is_integer(id) -> Repo.get!(Hashtag, id)
          # Race: another process created the row between our SELECT and INSERT.
          {:ok, _} -> Repo.get_by!(Hashtag, name: name)
          {:error, _} -> Repo.get_by!(Hashtag, name: name)
        end
    end
  end
end
