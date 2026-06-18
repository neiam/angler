defmodule Angler.Pagination.MastodonCursor do
  @moduledoc """
  Mastodon-style cursor pagination over a single integer key.

  The conventions:

  * `max_id` — return rows with `id < max_id`, ordered DESC. Used for "older".
  * `min_id` — return rows with `id > min_id`, ordered DESC after fetch.
                Used for "fill in newer between two known points".
  * `since_id` — return rows with `id > since_id`, ordered DESC.
                  Used for "newer than this".
  * `limit` — caller-supplied cap; clamped per endpoint.

  When both `max_id` and `since_id` are present, `since_id` wins (Mastodon
  spec). When `min_id` is present, results are fetched ASC then re-sorted
  DESC so the response is always newest-first.

  See `plans/_types/link_header.md`.
  """

  @type cursor :: %{
          max_id: integer() | nil,
          min_id: integer() | nil,
          since_id: integer() | nil,
          limit: pos_integer()
        }

  @doc """
  Parse `query_params` (string-keyed) into a cursor struct.

  `default_limit` and `max_limit` are endpoint-specific; e.g. timelines
  default 20 / max 40, account followers default 40 / max 80.
  """
  @spec parse(map(), pos_integer(), pos_integer()) :: cursor()
  def parse(params, default_limit, max_limit) when is_map(params) do
    %{
      max_id: parse_cursor_id(params["max_id"]),
      min_id: parse_cursor_id(params["min_id"]),
      since_id: parse_cursor_id(params["since_id"]),
      limit: clamp_limit(parse_int(params["limit"]) || default_limit, max_limit)
    }
  end

  @doc """
  Apply the cursor to an Ecto query, returning a new query.

  `binding` is the named binding to compare against; `key_field` is the
  field on that binding (typically `:id`).

      from(s in Status)
      |> MastodonCursor.apply(cursor, :id)
  """
  @spec apply(Ecto.Queryable.t(), cursor(), atom()) :: Ecto.Query.t()
  def apply(queryable, cursor, key_field \\ :id) do
    require Ecto.Query
    import Ecto.Query

    q = queryable

    q =
      cond do
        cursor.since_id ->
          where(q, [r], field(r, ^key_field) > ^cursor.since_id)

        cursor.max_id ->
          where(q, [r], field(r, ^key_field) < ^cursor.max_id)

        cursor.min_id ->
          where(q, [r], field(r, ^key_field) > ^cursor.min_id)

        true ->
          q
      end

    # min_id semantics: fetch ascending then sort descending after the limit
    # so the page is "page of N just above min_id" newest-first.
    asc? = is_integer(cursor.min_id)

    q
    |> order_by([r], [{^if(asc?, do: :asc, else: :desc), field(r, ^key_field)}])
    |> limit(^cursor.limit)
  end

  @doc """
  After-fetch step that ensures the result is descending by the cursor key.

  Pair with `apply/3` so callers don't have to know about the asc-then-flip
  trick for `min_id`.
  """
  @spec finalize_order([map()] | [struct()], cursor(), atom()) :: list()
  def finalize_order(rows, %{min_id: min_id}, key_field) when is_integer(min_id) do
    Enum.sort_by(rows, &Map.fetch!(&1, key_field), :desc)
  end

  def finalize_order(rows, _, _), do: rows

  @doc """
  Build a Link header value (or `nil` for empty results).

  `request_url` is the full incoming URL **without** the cursor params
  (e.g., `Phoenix.Controller.current_url/2` minus `max_id`/`min_id`/`since_id`).
  `key_field` is the cursor field on each row (usually `:id`).
  """
  @spec link_header(list(), String.t(), atom()) :: String.t() | nil
  def link_header([], _url, _field), do: nil

  def link_header(rows, request_url, key_field) do
    [first | _] = rows
    last = List.last(rows)

    first_id = Map.fetch!(first, key_field)
    last_id = Map.fetch!(last, key_field)

    next = build_url(request_url, max_id: last_id)
    prev = build_url(request_url, min_id: first_id)

    ~s(<#{next}>; rel="next", <#{prev}>; rel="prev")
  end

  ## Internals

  # Cursor ids are positive snowflakes; clients (e.g. pixelfed-rn) send `0` as
  # the initial page param to mean "from the start". Treat any non-positive id
  # as unset so we don't emit `where id < 0` and return an empty first page.
  defp parse_cursor_id(v) do
    case parse_int(v) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(int) when is_integer(int), do: int

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp clamp_limit(nil, max), do: max
  defp clamp_limit(n, _max) when n < 1, do: 1
  defp clamp_limit(n, max) when n > max, do: max
  defp clamp_limit(n, _), do: n

  defp build_url(base, replacements) do
    uri = URI.parse(base)
    existing = URI.decode_query(uri.query || "")

    # Strip prior cursor params; replace with the new one only.
    cleaned =
      existing
      |> Map.drop(["max_id", "min_id", "since_id"])
      |> Map.merge(Map.new(replacements, fn {k, v} -> {Atom.to_string(k), to_string(v)} end))

    %URI{uri | query: URI.encode_query(cleaned)} |> URI.to_string()
  end
end
