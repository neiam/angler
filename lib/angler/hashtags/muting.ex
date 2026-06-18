defmodule Angler.Hashtags.Muting do
  @moduledoc """
  Per-user hashtag mute lifecycle. Pairs with `Angler.Hashtags.Following`.

  A mute carries a `filter_action` (`blur` / `warn` / `hide`) that
  `Angler.Filters.Matching` applies at render time to any status bearing the
  muted tag.
  """

  import Ecto.Query, warn: false

  alias Angler.Hashtags
  alias Angler.Hashtags.{Hashtag, Mute}
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @doc """
  Mute `name` for `profile` with the given action (default `"hide"`). Upserts,
  so re-muting updates the action.
  """
  @spec mute(Profile.t(), String.t(), String.t()) :: {:ok, Hashtag.t()} | {:error, term()}
  def mute(%Profile{id: profile_id}, name, action \\ "hide") when is_binary(name) do
    tag = Hashtags.ensure!(name)

    %{profile_id: profile_id, hashtag_id: tag.id, filter_action: action}
    |> Mute.changeset()
    |> Repo.insert(
      on_conflict: {:replace, [:filter_action]},
      conflict_target: [:profile_id, :hashtag_id]
    )
    |> case do
      {:ok, _} -> {:ok, tag}
      err -> err
    end
  end

  @spec unmute(Profile.t(), String.t()) :: :ok
  def unmute(%Profile{id: profile_id}, name) when is_binary(name) do
    name = String.trim_leading(name, "#") |> String.downcase()

    case Hashtags.get_by_name(name) do
      nil ->
        :ok

      %Hashtag{id: hashtag_id} ->
        from(m in Mute, where: m.profile_id == ^profile_id and m.hashtag_id == ^hashtag_id)
        |> Repo.delete_all()

        :ok
    end
  end

  @spec muted?(integer(), integer()) :: boolean()
  def muted?(profile_id, hashtag_id) do
    Repo.exists?(
      from m in Mute, where: m.profile_id == ^profile_id and m.hashtag_id == ^hashtag_id
    )
  end

  @doc "Followed-tags-style list: `[{hashtag, action}]`, newest first."
  @spec list(integer(), pos_integer()) :: [{Hashtag.t(), String.t()}]
  def list(profile_id, limit \\ 100) do
    Repo.all(
      from m in Mute,
        join: h in Hashtag,
        on: h.id == m.hashtag_id,
        where: m.profile_id == ^profile_id,
        order_by: [desc: m.id],
        limit: ^limit,
        select: {h, m.filter_action}
    )
  end

  @doc "Map of `hashtag_id => filter_action` for a viewer. Used by the matcher."
  @spec action_map(integer()) :: %{integer() => String.t()}
  def action_map(profile_id) when is_integer(profile_id) do
    Repo.all(
      from m in Mute,
        where: m.profile_id == ^profile_id,
        select: {m.hashtag_id, m.filter_action}
    )
    |> Map.new()
  end
end
