defmodule Angler.Federation.Nodeinfo do
  @moduledoc """
  Builds the nodeinfo well-known + 2.0 documents.

  Counters come from `Angler.Instance.stats/0` (computed live, cached for half
  an hour) — the same numbers `/api/v1/instance` reports.
  """

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
    stats = Angler.Instance.stats()
    domain = URI.parse(AnglerWeb.Endpoint.url()).host

    %{
      "version" => "2.0",
      "software" => %{
        "name" => "pixelfed",
        "version" => @pixelfed_compat
      },
      "protocols" => ["activitypub"],
      "services" => %{"outbound" => [], "inbound" => []},
      "openRegistrations" => Angler.Instance.open_registration?(),
      "usage" => %{
        "users" => %{
          "total" => stats.user_count,
          "activeMonth" => stats.active_month,
          "activeHalfyear" => stats.active_halfyear
        },
        "localPosts" => stats.status_count,
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
end
