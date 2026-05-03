defmodule AnglerWeb.MastodonAPI.InstanceController do
  @moduledoc """
  GET /api/v1/instance + GET /api/v2/instance. Anonymous; mobile clients hit
  these on every cold-start to discover server capabilities.
  """

  use AnglerWeb, :controller

  alias Angler.Instance
  alias AnglerWeb.MastodonAPI.Account

  @version "0.1.0 (compatible; Angler 0.1.0)"
  @max_caption_chars 5000
  @max_media_attachments 10
  @max_image_bytes 25 * 1_048_576
  @max_video_bytes 100 * 1_048_576

  def show_v1(conn, _params) do
    stats = Instance.stats()
    contact = Instance.contact_profile()
    base = AnglerWeb.Endpoint.url()

    json(conn, %{
      "uri" => host(),
      "title" => Instance.title(),
      "short_description" => Instance.short_description(),
      "description" => Instance.description(),
      "email" => Instance.contact_email(),
      "version" => @version,
      "urls" => %{"streaming_api" => nil},
      "stats" => %{
        "user_count" => stats.user_count,
        "status_count" => stats.status_count,
        "domain_count" => stats.domain_count
      },
      "thumbnail" =>
        Application.get_env(:angler, :instance_banner_url) || base <> "/images/banner.jpg",
      "languages" => ["en"],
      "registrations" => Instance.open_registration?(),
      "approval_required" => Instance.approval_required?(),
      "invites_enabled" => false,
      "contact_account" => if(contact, do: Account.render(contact), else: nil),
      "rules" => render_rules(Instance.rules()),
      "configuration" => configuration_block()
    })
  end

  def show_v2(conn, _params) do
    contact = Instance.contact_profile()
    base = AnglerWeb.Endpoint.url()
    banner = Application.get_env(:angler, :instance_banner_url) || base <> "/images/banner.jpg"

    json(conn, %{
      "domain" => host(),
      "title" => Instance.title(),
      "version" => @version,
      "source_url" => "https://github.com/gmorell/angler",
      "description" => Instance.short_description(),
      "usage" => %{
        "users" => %{"active_month" => Instance.stats().user_count}
      },
      "thumbnail" => %{
        "url" => banner,
        "blurhash" => nil,
        "versions" => %{"@1x" => banner, "@2x" => banner}
      },
      "languages" => ["en"],
      "configuration" => %{
        "urls" => %{"streaming" => nil, "status" => nil},
        "vapid" => %{"public_key" => nil},
        "accounts" => %{"max_featured_tags" => 0},
        "statuses" => %{
          "max_characters" => @max_caption_chars,
          "max_media_attachments" => @max_media_attachments,
          "characters_reserved_per_url" => 23
        },
        "media_attachments" => media_attachments_block(),
        "polls" => %{
          "max_options" => Angler.Polls.max_options(),
          "max_characters_per_option" => 50,
          "min_expiration" => 60,
          "max_expiration" => 7 * 86_400
        },
        "translation" => %{"enabled" => false}
      },
      "registrations" => %{
        "enabled" => Instance.open_registration?(),
        "approval_required" => Instance.approval_required?(),
        "message" => nil,
        "url" => nil
      },
      "contact" => %{
        "email" => Instance.contact_email(),
        "account" => if(contact, do: Account.render(contact), else: nil)
      },
      "rules" => render_rules(Instance.rules())
    })
  end

  def peers(conn, _params), do: json(conn, [])

  ## Helpers

  defp configuration_block do
    %{
      "media_attachments" => media_attachments_block(),
      "polls" => %{
        "max_options" => Angler.Polls.max_options(),
        "max_characters_per_option" => 50,
        "min_expiration" => 60,
        "max_expiration" => 7 * 86_400
      },
      "statuses" => %{
        "characters_reserved_per_url" => 23,
        "max_characters" => @max_caption_chars,
        "max_media_attachments" => @max_media_attachments
      }
    }
  end

  defp media_attachments_block do
    %{
      "supported_mime_types" =>
        ~w(image/jpeg image/png image/webp image/gif video/mp4 video/webm video/quicktime),
      "image_size_limit" => @max_image_bytes,
      "image_matrix_limit" => 16_777_216,
      "video_size_limit" => @max_video_bytes,
      "video_frame_rate_limit" => 120,
      "video_matrix_limit" => 16_777_216
    }
  end

  defp render_rules(rules) do
    rules
    |> Enum.with_index(1)
    |> Enum.map(fn {text, idx} -> %{"id" => Integer.to_string(idx), "text" => text} end)
  end

  defp host do
    AnglerWeb.Endpoint.url() |> URI.parse() |> Map.get(:host) || "localhost"
  end
end
