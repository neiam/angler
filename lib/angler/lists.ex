defmodule Angler.Lists do
  @moduledoc """
  User-curated lists. The viewer must follow every account they add (Mastodon
  rule); we enforce it as a soft check on `add_accounts/3` so unfollowed
  accounts get silently skipped rather than 422'd.
  """

  import Ecto.Query, warn: false

  alias Angler.Follows.Follower
  alias Angler.Lists.{List, ListAccount}
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status

  ## Lists

  @spec list_for(integer()) :: [List.t()]
  def list_for(profile_id) when is_integer(profile_id) do
    Repo.all(
      from l in List,
        where: l.profile_id == ^profile_id,
        order_by: [desc: l.id]
    )
  end

  @spec get(integer(), integer()) :: List.t() | nil
  def get(profile_id, id), do: Repo.get_by(List, id: id, profile_id: profile_id)

  @spec create(integer(), map()) :: {:ok, List.t()} | {:error, Ecto.Changeset.t()}
  def create(profile_id, attrs) when is_integer(profile_id) do
    attrs = Map.put(attrs, "profile_id", profile_id)
    %List{} |> List.changeset(attrs) |> Repo.insert()
  end

  @spec update(List.t(), map()) :: {:ok, List.t()} | {:error, Ecto.Changeset.t()}
  def update(%List{} = list, attrs), do: list |> List.changeset(attrs) |> Repo.update()

  @spec delete(List.t()) :: :ok
  def delete(%List{} = list) do
    Repo.delete!(list)
    :ok
  end

  ## Members

  @doc """
  Add `account_ids` to the list. Silently drops ids the owner doesn't
  follow (matches Mastodon's behavior — clients always send a clean list
  but races happen).
  """
  @spec add_accounts(List.t(), [integer()]) :: :ok
  def add_accounts(%List{id: list_id, profile_id: owner_id}, account_ids)
      when is_list(account_ids) do
    followed =
      Repo.all(
        from f in Follower,
          where:
            f.following_id == ^owner_id and f.profile_id in ^account_ids and
              not is_nil(f.accepted_at),
          select: f.profile_id
      )
      |> MapSet.new()

    rows =
      account_ids
      |> Enum.filter(&MapSet.member?(followed, &1))
      |> Enum.map(fn pid ->
        %{list_id: list_id, profile_id: pid, inserted_at: DateTime.utc_now()}
      end)

    if rows != [] do
      Repo.insert_all(ListAccount, rows,
        on_conflict: :nothing,
        conflict_target: [:list_id, :profile_id]
      )
    end

    :ok
  end

  @spec remove_accounts(List.t(), [integer()]) :: :ok
  def remove_accounts(%List{id: list_id}, account_ids) when is_list(account_ids) do
    {_, _} =
      from(la in ListAccount,
        where: la.list_id == ^list_id and la.profile_id in ^account_ids
      )
      |> Repo.delete_all()

    :ok
  end

  @spec accounts(List.t(), pos_integer()) :: [Profile.t()]
  def accounts(%List{id: list_id}, limit \\ 40) do
    Repo.all(
      from la in ListAccount,
        join: p in Profile,
        on: p.id == la.profile_id,
        where: la.list_id == ^list_id and is_nil(p.status),
        order_by: [desc: la.id],
        limit: ^limit,
        select: p
    )
  end

  @spec lists_containing(integer(), integer()) :: [List.t()]
  def lists_containing(owner_id, account_id) do
    Repo.all(
      from la in ListAccount,
        join: l in List,
        on: l.id == la.list_id,
        where: la.profile_id == ^account_id and l.profile_id == ^owner_id,
        select: l
    )
  end

  ## Timeline

  @spec timeline(List.t(), keyword()) :: [Status.t()]
  def timeline(%List{id: list_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(
      from la in ListAccount,
        join: s in Status,
        on:
          s.profile_id == la.profile_id and is_nil(s.deleted_at) and
            s.visibility in [:public, :unlisted, :private],
        where: la.list_id == ^list_id,
        order_by: [desc: s.id],
        limit: ^limit,
        preload: [:profile, mentions: :profile, status_hashtags: :hashtag, media_attachments: []],
        select: s
    )
  end
end
