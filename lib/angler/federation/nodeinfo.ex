defmodule Angler.Federation.Nodeinfo do
  @moduledoc """
  Builds the nodeinfo well-known + 2.0 documents.

  Counters come from the `node_stats` singleton row, which a periodic worker
  will refresh later. Until that worker exists, the row stays at zeros — the
  document still validates against the spec.
  """

  import Ecto.Query, only: [from: 2]
  alias Angler.Repo

  # The top-level `software` block reports the Pixelfed API surface we implement
  # (`name: "pixelfed"`, a >= 0.12.3 version). The pixelfed-rn mobile app gates
  # login on `software.name == "pixelfed"` AND `software.version >= 0.12.3` in
  # its nodeinfo preflight, with no "compatible" fallback — reporting `angler`
  # here makes it refuse to connect ("Invalid or outdated version"). Angler's
  # real identity + version live under `metadata.software` (and the Pixelfed
  # level is echoed in `metadata.compatible`) for peers that look deeper.
  @pixelfed_compat "0.12.7"

  # Angler's version, read from the loaded application (works in releases where
  # Mix isn't available).
  @spec version() :: String.t()
  def version, do: Application.spec(:angler, :vsn) |> to_string()

  @doc "GET /.well-known/nodeinfo"
  @spec well_known() :: map()
  def well_known do
    %{
      "links" => [
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
          "href" => AnglerWeb.Endpoint.url() <> "/api/nodeinfo/2.0.json"
        }
      ]
    }
  end

  @doc "GET /api/nodeinfo/2.0.json"
  @spec document() :: map()
  def document do
    stats = stats()
    domain = URI.parse(AnglerWeb.Endpoint.url()).host

    %{
      "version" => "2.0",
      "software" => %{
        "name" => "pixelfed",
        "version" => @pixelfed_compat
      },
      "protocols" => ["activitypub"],
      "services" => %{"outbound" => [], "inbound" => []},
      "openRegistrations" => true,
      "usage" => %{
        "users" => %{
          "total" => stats.user_count,
          "activeMonth" => stats.active_month,
          "activeHalfyear" => stats.active_halfyear
        },
        "localPosts" => stats.local_posts,
        "localComments" => stats.local_comments
      },
      "metadata" => %{
        "nodeName" => domain,
        "software" => %{
          "name" => "Angler",
          "version" => version(),
          "homepage" => "https://neiam.org"
        },
        "config" => %{
          "features" => ["mobile_apis"]
        },
        "compatible" => %{
          "pixelfed" => @pixelfed_compat
        }
      }
    }
  end

  @doc "Read the singleton stats row, defaulting to zeros if it doesn't exist yet."
  @spec stats() :: %{
          user_count: integer(),
          status_count: integer(),
          domain_count: integer(),
          active_month: integer(),
          active_halfyear: integer(),
          local_posts: integer(),
          local_comments: integer()
        }
  def stats do
    row =
      from(s in "node_stats",
        where: s.id == 1,
        select: %{
          user_count: s.user_count,
          status_count: s.status_count,
          domain_count: s.domain_count,
          active_month: s.active_month,
          active_halfyear: s.active_halfyear,
          local_posts: s.local_posts,
          local_comments: s.local_comments
        }
      )
      |> Repo.one()

    row ||
      %{
        user_count: 0,
        status_count: 0,
        domain_count: 0,
        active_month: 0,
        active_halfyear: 0,
        local_posts: 0,
        local_comments: 0
      }
  end
end
