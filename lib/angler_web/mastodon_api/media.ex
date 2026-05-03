defmodule AnglerWeb.MastodonAPI.Media do
  @moduledoc """
  Render an `Angler.Media.Asset` as a Mastodon `MediaAttachment` JSON object.
  """

  alias Angler.Media.Asset
  alias Angler.Media.Storage

  @default_blurhash "U4Rfzst8?bt7ogayj[j[~pfQ9Goe%Mj[WBay"

  @spec render(Asset.t()) :: map()
  def render(%Asset{} = m) do
    base = %{
      "id" => Integer.to_string(m.id),
      "type" => mastodon_type(m.media_type),
      "url" => Storage.url(m, :original),
      "preview_url" => Storage.url(m, :preview) || Storage.url(m, :original),
      "remote_url" => m.remote_url,
      "text_url" => Storage.url(m, :original),
      "description" => m.caption,
      "blurhash" => m.blurhash || @default_blurhash
    }

    if m.width && m.height do
      Map.put(base, "meta", %{
        "focus" => %{"x" => 0, "y" => 0},
        "original" => %{
          "width" => m.width,
          "height" => m.height,
          "size" => "#{m.width}x#{m.height}",
          "aspect" => m.width / m.height
        }
      })
    else
      base
    end
  end

  @spec render_many([Asset.t()]) :: [map()]
  def render_many(assets), do: Enum.map(assets, &render/1)

  defp mastodon_type("image/gif"), do: "gifv"
  defp mastodon_type("image/" <> _), do: "image"
  defp mastodon_type("video/" <> _), do: "video"
  defp mastodon_type("audio/" <> _), do: "audio"
  defp mastodon_type(_), do: "unknown"
end
