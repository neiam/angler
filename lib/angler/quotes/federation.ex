defmodule Angler.Quotes.Federation do
  @moduledoc """
  Inbound FEP-044f `QuoteRequest`: a remote actor asks to quote a local post.

  Anything that doesn't name a real remote requester and a quotable local
  post is dropped without an answer, so a request can't probe for private
  posts. Otherwise the answer is always an `Accept` carrying the stamp or a
  `Reject` (upstream HandlesQuoteRequests).
  """

  require Logger

  alias Angler.Federation.Actor
  alias Angler.Profiles.Profile
  alias Angler.Quotes
  alias Angler.Quotes.Authorization
  alias Angler.Quotes.Workers.QuoteDeliver
  alias Angler.Statuses
  alias Angler.Statuses.Status

  # Properties a quote post may point at what it quotes with.
  @quote_properties ~w(quote quoteUrl quoteUri _misskey_quote)

  @doc "`actor_url` is the signature-verified sender."
  @spec handle_quote_request(map(), String.t()) :: :ok
  def handle_quote_request(%{"id" => request_url} = activity, actor_url)
      when is_binary(request_url) do
    with true <- Actor.same_actor?(url_field(activity["actor"]), actor_url),
         true <- Actor.same_host?(request_url, actor_url),
         {:ok, %Profile{domain: d} = actor} when is_binary(d) <- Actor.resolve(actor_url),
         quote_url when is_binary(quote_url) <- instrument_url(activity, actor_url),
         %Status{} = status <- target(activity) do
      answer(status, actor, quote_url, request_url, activity)
    else
      _ -> :ok
    end
  end

  def handle_quote_request(_, _), do: :ok

  defp answer(status, actor, quote_url, request_url, activity) do
    case Quotes.find(status.id, quote_url) do
      %Authorization{state: "revoked"} ->
        reject(status, actor, quote_url, request_url)

      # A live stamp already covers this quote post: answer with it. The
      # quote url is only bound to the requester's host, so a co-hosted
      # requester gets the same stamp, addressed to them.
      %Authorization{} = auth ->
        accept(auth, actor, request_url)

      nil ->
        if Quotes.can_quote?(status, actor) and instrument_matches?(activity, actor, status) do
          status |> Quotes.authorize(actor, quote_url, request_url) |> accept(actor, request_url)
        else
          Logger.info("QuoteRequest rejected: actor=#{actor.id} status=#{status.id}")
          reject(status, actor, quote_url, request_url)
        end
    end
  end

  defp accept(auth, actor, request_url) do
    {:ok, _} =
      QuoteDeliver.enqueue(
        auth.profile_id,
        actor.id,
        Quotes.accept_activity(auth, actor, request_url)
      )

    :ok
  end

  defp reject(status, actor, quote_url, request_url) do
    activity = Quotes.reject_activity(status, actor, quote_url, request_url)
    {:ok, _} = QuoteDeliver.enqueue(status.profile_id, actor.id, activity)
    :ok
  end

  # The quote post's id, exactly as sent (the quoter compares the stamp's
  # interactingObject byte for byte), and on the requester's host.
  defp instrument_url(activity, actor_url) do
    case url_field(activity["instrument"]) do
      url when is_binary(url) and byte_size(url) <= 500 ->
        if Actor.same_host?(url, actor_url), do: url

      _ ->
        nil
    end
  end

  # An inlined quote post has to be what the request says: by the requester,
  # quoting this post. A bare id passes; their server speaks for its objects.
  defp instrument_matches?(activity, actor, status) do
    case ld_node(activity["instrument"]) do
      %{} = instrument ->
        author_ok? =
          not Map.has_key?(instrument, "attributedTo") or
            Actor.same_actor?(url_field(instrument["attributedTo"]), actor.remote_url)

        author_ok? and
          Enum.all?(@quote_properties, fn prop ->
            case Map.fetch(instrument, prop) do
              :error -> true
              {:ok, v} -> match?(%Status{id: id} when id == status.id, lookup(url_field(v)))
            end
          end)

      _ ->
        true
    end
  end

  # The local post being quoted, if it's quotable at all.
  defp target(activity) do
    with %Status{local: true} = status <- lookup(url_field(activity["object"])),
         true <- Quotes.quotable?(status) do
      status
    else
      _ -> nil
    end
  end

  defp lookup(url) when is_binary(url), do: Statuses.get_by_ap_id(url)
  defp lookup(_), do: nil

  # A JSON-LD value may be one node or a list of them.
  defp ld_node([first | _]), do: ld_node(first)
  defp ld_node(v) when is_binary(v) or is_map(v), do: v
  defp ld_node(_), do: nil

  defp url_field(value) do
    case ld_node(value) do
      %{"id" => id} when is_binary(id) -> http_url(id)
      id when is_binary(id) -> http_url(id)
      _ -> nil
    end
  end

  defp http_url(s) do
    s = String.trim(s)

    case URI.parse(s) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> s
      _ -> nil
    end
  end
end
