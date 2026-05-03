defmodule AnglerWeb.MastodonAPI.Relationship do
  @moduledoc """
  Render an `Angler.Relationships.t()` map as the Mastodon `Relationship`
  JSON object. See `plans/_types/relationship.md`.
  """

  @spec render(map()) :: map()
  def render(%{} = rel) do
    %{
      "id" => Integer.to_string(rel.id),
      "following" => rel.following,
      "showing_reblogs" => rel.showing_reblogs,
      "notifying" => rel.notifying,
      "followed_by" => rel.followed_by,
      "blocking" => rel.blocking,
      "blocked_by" => rel.blocked_by,
      "muting" => rel.muting,
      "muting_notifications" => rel.muting_notifications,
      "requested" => rel.requested,
      "requested_by" => rel.requested_by,
      "domain_blocking" => rel.domain_blocking,
      "endorsed" => rel.endorsed,
      "note" => rel.note
    }
  end

  @spec render_many([map()]) :: [map()]
  def render_many(rels), do: Enum.map(rels, &render/1)
end
