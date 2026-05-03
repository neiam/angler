defmodule Angler.Federation.Audience do
  @moduledoc """
  Resolve a list of local profile recipients from an inbound activity's
  `to`/`cc`/`bto`/`bcc`/`audience` fields.

  Public-target activities (`https://www.w3.org/ns/activitystreams#Public`)
  resolve to the special `:public` flag — handled at the timeline layer, not
  by per-user fanout.

  Used by the shared inbox to figure out which local users an activity is
  for. Per-user inboxes already know.
  """

  import Ecto.Query, warn: false
  alias Angler.Profiles.Profile
  alias Angler.Repo

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  @type result :: {:public_only | :targeted, [integer()]}

  @doc """
  Returns the local recipient profile ids for an activity.

  Examples:
    * Activity addressed to `as:Public` only → `{:public_only, []}`
    * Activity addressed to `as:Public` + a follower URL whose owner is local
      → `{:public_only, [follower_owner_id]}`
    * Activity addressed only to specific local actor URLs
      → `{:targeted, [ids]}`
  """
  @spec resolve(map()) :: result()
  def resolve(payload) when is_map(payload) do
    raw =
      [
        Map.get(payload, "to"),
        Map.get(payload, "cc"),
        Map.get(payload, "bto"),
        Map.get(payload, "bcc"),
        Map.get(payload, "audience")
      ]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.uniq()

    public? = @public_uri in raw

    usernames =
      raw
      |> Enum.flat_map(&extract_local_username/1)
      |> Enum.uniq()

    ids =
      if usernames == [] do
        []
      else
        from(p in Profile,
          where: p.username in ^usernames and is_nil(p.domain) and is_nil(p.status),
          select: p.id
        )
        |> Repo.all()
      end

    if public?, do: {:public_only, ids}, else: {:targeted, ids}
  end

  # Match `<our_base_url>/users/<username>` and pull out the username.
  # Anything else (foreign actor URL, public collection, follower collection
  # of a remote actor) is not a local-recipient signal.
  defp extract_local_username(@public_uri), do: []

  defp extract_local_username(url) when is_binary(url) do
    base = AnglerWeb.Endpoint.url() <> "/users/"

    if String.starts_with?(url, base) do
      [String.trim_leading(url, base)]
    else
      []
    end
  end

  defp extract_local_username(_), do: []
end
