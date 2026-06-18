defmodule Angler.Media.License do
  @moduledoc """
  Media licenses, mirroring Pixelfed's `App\\Util\\Media\\License` numbering so
  licenses survive federation and import/export round-trips between the two.

  The stored value on `media.license` is the integer id rendered as a string
  (Pixelfed stores it the same way). Id `1` ("All Rights Reserved") is the
  implicit default and is treated as "no license" — `get/1` returns `nil` for it
  so the API omits a license object, matching Pixelfed's `Media::getLicense()`.
  """

  @kb_url "/site/kb/licenses"

  @licenses [
    %{id: 1, title: "All Rights Reserved", name: "All Rights Reserved", url: @kb_url},
    %{id: 5, title: "Public Domain", name: "Public Domain Work", url: @kb_url},
    %{id: 6, title: "Public Domain (CC0)", name: "Public Domain Dedication (CC0)", url: @kb_url},
    %{
      id: 11,
      title: "CC BY",
      name: "Attribution",
      url: "https://creativecommons.org/licenses/by/4.0/"
    },
    %{
      id: 12,
      title: "CC BY-SA",
      name: "Attribution-ShareAlike",
      url: "https://creativecommons.org/licenses/by-sa/4.0/"
    },
    %{
      id: 13,
      title: "CC BY-NC",
      name: "Attribution-NonCommercial",
      url: "https://creativecommons.org/licenses/by-nc/4.0/"
    },
    %{
      id: 14,
      title: "CC BY-NC-SA",
      name: "Attribution-NonCommercial-ShareAlike",
      url: "https://creativecommons.org/licenses/by-nc-sa/4.0/"
    },
    %{
      id: 15,
      title: "CC BY-ND",
      name: "Attribution-NoDerivs",
      url: "https://creativecommons.org/licenses/by-nd/4.0/"
    },
    %{
      id: 16,
      title: "CC BY-NC-ND",
      name: "Attribution-NonCommercial-NoDerivs",
      url: "https://creativecommons.org/licenses/by-nc-nd/4.0/"
    }
  ]

  @ids Enum.map(@licenses, & &1.id)
  @default_id 1

  @type license :: %{id: pos_integer(), title: String.t(), name: String.t(), url: String.t()}

  @doc "The full ordered list of licenses (for select inputs / settings)."
  @spec all() :: [license()]
  def all, do: @licenses

  @doc "All valid license ids."
  @spec ids() :: [pos_integer()]
  def ids, do: @ids

  @doc "The implicit default id (All Rights Reserved)."
  @spec default_id() :: pos_integer()
  def default_id, do: @default_id

  @doc "True if `id` (integer or string) is a known license id."
  @spec valid?(integer() | String.t() | nil) :: boolean()
  def valid?(id), do: normalize(id) in @ids

  @doc """
  Look up a license for API/UI rendering. Returns `nil` for "All Rights
  Reserved" (id 1) or any unknown/blank value, so callers omit the license
  object — matching Pixelfed semantics. Accepts an integer or a string id.
  """
  @spec get(integer() | String.t() | nil) :: license() | nil
  def get(id) do
    case normalize(id) do
      n when n == @default_id -> nil
      n -> Enum.find(@licenses, &(&1.id == n))
    end
  end

  @doc """
  Coerce an arbitrary license input into the canonical stored string form, or
  `nil` when it's absent / "All Rights Reserved" / invalid (so we don't persist
  a redundant default). Used by the upload pipeline.
  """
  @spec normalize_stored(integer() | String.t() | nil) :: String.t() | nil
  def normalize_stored(id) do
    case normalize(id) do
      n when n == @default_id -> nil
      n when n in @ids -> Integer.to_string(n)
      _ -> nil
    end
  end

  defp normalize(id) when is_integer(id), do: id

  defp normalize(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp normalize(_), do: 0
end
