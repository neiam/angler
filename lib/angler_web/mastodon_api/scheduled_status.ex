defmodule AnglerWeb.MastodonAPI.ScheduledStatus do
  @moduledoc """
  Mastodon `ScheduledStatus` JSON shape.

      {
        "id": "...",
        "scheduled_at": "...",
        "params": { ... },
        "media_attachments": [...]
      }
  """

  alias Angler.Media.Asset
  alias Angler.Repo
  alias Angler.Statuses.Scheduled
  alias AnglerWeb.MastodonAPI.Media, as: MediaJSON
  import Ecto.Query, only: [from: 2]

  @spec render(Scheduled.t()) :: map()
  def render(%Scheduled{} = s) do
    %{
      "id" => Integer.to_string(s.id),
      "scheduled_at" => DateTime.to_iso8601(s.scheduled_at),
      "params" => s.params,
      "media_attachments" =>
        s.media_ids
        |> load_media()
        |> Enum.map(&MediaJSON.render/1)
    }
  end

  @spec render_many([Scheduled.t()]) :: [map()]
  def render_many(rows), do: Enum.map(rows, &render/1)

  defp load_media([]), do: []

  defp load_media(ids) when is_list(ids) do
    Repo.all(from a in Asset, where: a.id in ^ids)
  end
end
