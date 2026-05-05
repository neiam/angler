defmodule Angler.Collections do
  @moduledoc """
  Pixelfed-style curated photo collections. Owner-only writes; public reads
  respect the collection's `visibility` (`public | private | draft`):

    * `public` — anyone can read.
    * `private` — owner + viewer that follows owner.
    * `draft`  — owner-only.

  Items must be public/unlisted photo or video statuses owned by the same
  profile (Pixelfed rule).
  """

  import Ecto.Query, warn: false

  alias Angler.Collections.{Collection, Item}
  alias Angler.Follows.Follower
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Statuses.Status

  @max_items 18
  @media_types ~w(photo photo:album video)

  @doc "Maximum items a single collection can hold."
  def max_items, do: @max_items

  ## Reads

  @spec get(integer()) :: Collection.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Collection, id)

  @doc "Visible? Owner always; followers when private; everyone when public."
  @spec visible_to?(Collection.t(), integer() | nil) :: boolean()
  def visible_to?(%Collection{visibility: "public", published_at: %DateTime{}}, _), do: true
  def visible_to?(%Collection{profile_id: pid}, viewer_id) when pid == viewer_id, do: true

  def visible_to?(%Collection{visibility: "private", profile_id: pid}, viewer_id)
      when not is_nil(viewer_id) do
    Repo.exists?(
      from f in Follower,
        where: f.profile_id == ^pid and f.following_id == ^viewer_id and not is_nil(f.accepted_at)
    )
  end

  def visible_to?(_, _), do: false

  @spec for_profile(integer(), integer() | nil) :: [Collection.t()]
  def for_profile(profile_id, viewer_id) do
    visibilities = visibilities_for(profile_id, viewer_id)

    Repo.all(
      from c in Collection,
        where:
          c.profile_id == ^profile_id and c.visibility in ^visibilities and
            (^owner?(profile_id, viewer_id) or not is_nil(c.published_at)),
        order_by: [desc: c.id],
        limit: 30
    )
  end

  @spec for_self(integer()) :: [Collection.t()]
  def for_self(profile_id) do
    Repo.all(
      from c in Collection,
        where: c.profile_id == ^profile_id,
        order_by: [desc: c.id],
        limit: 30
    )
  end

  @spec items(Collection.t(), pos_integer(), non_neg_integer()) :: [Status.t()]
  def items(%Collection{id: id}, limit \\ 10, offset \\ 0) do
    Repo.all(
      from i in Item,
        join: s in Status,
        on: s.id == i.status_id and is_nil(s.deleted_at),
        where:
          i.collection_id == ^id and
            fragment("?::text", s.visibility) in ["public", "unlisted"],
        order_by: [asc: i.position, asc: i.id],
        limit: ^limit,
        offset: ^offset,
        select: s
    )
    |> Repo.preload([
      :profile,
      mentions: :profile,
      status_hashtags: :hashtag,
      media_attachments: []
    ])
  end

  @spec item_count(Collection.t()) :: non_neg_integer()
  def item_count(%Collection{id: id}) do
    Repo.aggregate(from(i in Item, where: i.collection_id == ^id), :count)
  end

  ## Writes

  @spec create(integer()) :: {:ok, Collection.t()} | {:error, Ecto.Changeset.t()}
  def create(profile_id) when is_integer(profile_id) do
    %Collection{}
    |> Collection.changeset(%{profile_id: profile_id, visibility: "draft"})
    |> Repo.insert()
  end

  @spec update(Collection.t(), map()) :: {:ok, Collection.t()} | {:error, Ecto.Changeset.t()}
  def update(%Collection{} = c, attrs) do
    attrs = sanitize(attrs)

    attrs =
      case attrs["visibility"] do
        v when v in ["public", "private"] and is_nil(c.published_at) ->
          Map.put(attrs, "published_at", DateTime.utc_now())

        _ ->
          attrs
      end

    c |> Collection.changeset(attrs) |> Repo.update()
  end

  @spec delete(Collection.t()) :: :ok
  def delete(%Collection{} = c) do
    Repo.delete!(c)
    :ok
  end

  @spec add_item(Collection.t(), Profile.t(), integer()) ::
          {:ok, Status.t()} | {:error, atom()}
  def add_item(%Collection{profile_id: pid}, %Profile{id: viewer_id}, _)
      when pid != viewer_id,
      do: {:error, :forbidden}

  def add_item(%Collection{} = c, %Profile{}, status_id) do
    case Repo.get(Status, status_id) do
      nil ->
        {:error, :not_found}

      %Status{profile_id: spid} when spid != c.profile_id ->
        {:error, :forbidden}

      %Status{visibility: v} when v not in [:public, :unlisted] ->
        {:error, :unaddable}

      %Status{type: t} when t not in @media_types ->
        {:error, :unaddable}

      %Status{} = status ->
        do_add(c, status)
    end
  end

  defp do_add(%Collection{} = c, %Status{} = status) do
    count = item_count(c)

    if count >= @max_items do
      {:error, :limit_reached}
    else
      %{collection_id: c.id, status_id: status.id, position: count}
      |> Item.changeset()
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:collection_id, :status_id]
      )

      Repo.update_all(
        from(c2 in Collection, where: c2.id == ^c.id),
        set: [updated_at: DateTime.utc_now()]
      )

      {:ok, status}
    end
  end

  @spec remove_item(Collection.t(), Profile.t(), integer()) :: :ok | {:error, atom()}
  def remove_item(%Collection{profile_id: pid}, %Profile{id: viewer_id}, _)
      when pid != viewer_id,
      do: {:error, :forbidden}

  def remove_item(%Collection{} = c, %Profile{}, status_id) do
    if item_count(c) <= 1 do
      {:error, :last_item}
    else
      from(i in Item, where: i.collection_id == ^c.id and i.status_id == ^status_id)
      |> Repo.delete_all()

      reorder!(c.id)
      :ok
    end
  end

  defp reorder!(collection_id) do
    Repo.all(
      from i in Item,
        where: i.collection_id == ^collection_id,
        order_by: [asc: i.position, asc: i.id]
    )
    |> Enum.with_index()
    |> Enum.each(fn {item, idx} ->
      if item.position != idx do
        item |> Ecto.Changeset.change(position: idx) |> Repo.update!()
      end
    end)
  end

  ## Internals

  defp sanitize(attrs) when is_map(attrs) do
    Map.take(attrs, ["title", "description", "visibility", "published_at"])
    |> Enum.into(%{}, fn
      {"title", v} when is_binary(v) -> {"title", strip_html(v)}
      {"description", v} when is_binary(v) -> {"description", strip_html(v)}
      kv -> kv
    end)
  end

  defp strip_html(s) when is_binary(s) do
    s |> String.replace(~r/<[^>]*>/, "") |> String.trim()
  end

  defp owner?(profile_id, viewer_id), do: profile_id == viewer_id

  defp visibilities_for(profile_id, viewer_id) do
    cond do
      profile_id == viewer_id ->
        ~w(public private draft)

      viewer_id &&
          Repo.exists?(
            from f in Follower,
              where:
                f.profile_id == ^profile_id and f.following_id == ^viewer_id and
                    not is_nil(f.accepted_at)
          ) ->
        ~w(public private)

      true ->
        ~w(public)
    end
  end
end
