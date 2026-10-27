defmodule AnglerWeb.MastodonAPI.InstanceController do
  @moduledoc """
  GET /api/v1/instance + GET /api/v2/instance. Anonymous; mobile clients hit
  these on every cold-start to discover server capabilities.
  """

  use AnglerWeb, :controller

  alias Angler.Instance
  alias AnglerWeb.MastodonAPI.Account

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
      "version" => version(),
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
      "version" => version(),
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

  @doc """
  `GET /api/v2.1/config` — the bootstrap config the new Pixelfed app and
  web UI read before anything else (upstream `AppService::getConfig`,
  9d82d7637). `version` is the Pixelfed release we report compatibility
  with, the same number nodeinfo advertises.
  """
  def app_config(conn, _params) do
    json(conn, %{
      "version" => Angler.Federation.Nodeinfo.pixelfed_compat(),
      "oauth" => true,
      "signup" => %{
        "curated" => false,
        "mobile_registration" =>
          Instance.open_registration?() and
            Application.get_env(:angler, :in_app_registration_enabled, false) == true
      },
      "features" => %{
        "stories" => Angler.Stories.enabled?(),
        "video" => true,
        "timelines" => %{"local" => true, "network" => true}
      },
      "limits" => %{
        "account" => %{
          "max_avatar_size" => div(@max_image_bytes, 1024),
          "max_bio_length" => 200,
          "max_name_length" => 30,
          "min_password_length" => 8
        },
        "collections" => %{"max_collection_length" => Angler.Collections.max_items()},
        # DMs are ordinary direct statuses here, under the status limits;
        # group chats need the v0.15 DM API, which Angler doesn't have yet.
        "direct_messages" => %{
          "max_characters" => @max_caption_chars,
          "max_media_attachments" => @max_media_attachments,
          "group_chats" => %{"enabled" => false, "max_participants" => 0}
        },
        "media" => %{
          "image_size_limit" => @max_image_bytes,
          "max_album_limit" => @max_media_attachments,
          "max_alt_text_length" => 1500,
          "supported_mime_types" => media_attachments_block()["supported_mime_types"],
          "video_size_limit" => @max_video_bytes
        },
        "statuses" => %{"max_characters" => @max_caption_chars}
      }
    })
  end

  # Upstream's exact format, "<mastodon api> (compatible; Pixelfed <x>)":
  # Mastodon client libraries read the leading number as the Mastodon API
  # level and gate features on it, and Pixelfed clients look for the
  # Pixelfed release in the parentheses. Angler's own name and version are
  # in nodeinfo's metadata.software.
  defp version,
    do: "3.5.3 (compatible; Pixelfed #{Angler.Federation.Nodeinfo.pixelfed_compat()})"

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
