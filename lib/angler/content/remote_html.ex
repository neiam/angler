defmodule Angler.Content.RemoteHtml do
  @moduledoc """
  Make a remote post's HTML safe to show, and point its hashtags here.

  Remote `content` is stored as the origin server sent it, so it's cleaned
  on the way out: MDEx's ammonia-based sanitizer drops scripts, event
  handlers, `javascript:` URLs and anything else outside its allowlist,
  keeping the microformat classes clients style mentions and hashtags with.

  A hashtag link (`#<span>cats</span>` pointing at the origin's tag page)
  is rewritten to our `/tags/:name` when the post carries that tag, so
  following it stays on this server.
  """

  @sanitize [
    add_allowed_classes: %{
      "a" => ["mention", "hashtag", "u-url", "status-link"],
      "span" => ["h-card", "invisible", "ellipsis"]
    }
  ]

  @anchor ~r{<a\s([^>]*?)href="([^"]*)"([^>]*)>(.*?)</a>}s

  @doc "Sanitized HTML, with hashtag links to `hashtags` (names) rewritten."
  @spec clean(String.t() | nil, [String.t()]) :: String.t()
  def clean(html, hashtags \\ [])
  def clean(nil, _), do: ""
  def clean("", _), do: ""

  def clean(html, hashtags) when is_binary(html) do
    html
    |> MDEx.safe_html(sanitize: @sanitize, escape: [content: false, curly_braces_in_code: false])
    |> localize_hashtags(MapSet.new(hashtags, &String.downcase/1))
  end

  defp localize_hashtags(html, tags) do
    if MapSet.size(tags) == 0 do
      html
    else
      base = AnglerWeb.Endpoint.url() <> "/tags/"

      Regex.replace(@anchor, html, fn whole, pre, _href, post, inner ->
        with "#" <> name <- inner |> String.replace(~r/<[^>]*>/, "") |> String.trim(),
             true <- MapSet.member?(tags, String.downcase(name)) do
          ~s(<a #{pre}href="#{base}#{URI.encode(String.downcase(name))}"#{post}>#{inner}</a>)
        else
          _ -> whole
        end
      end)
    end
  end
end
