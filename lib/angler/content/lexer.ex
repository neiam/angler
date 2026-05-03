defmodule Angler.Content.Lexer do
  @moduledoc """
  Single-pass caption tokenizer + HTML renderer.

  Scans the input for `@username`, `#hashtag`, and `https://…` URLs, and
  emits an HTML-escaped string with each entity wrapped in an `<a>` tag.
  Returns the html plus the lists of recognised mention usernames and
  hashtag names so the caller can persist `mentions` / `status_hashtags`.

  Scope cuts for this slice (documented as TODOs):

  * Only **local** `@username` mentions are linked. `@user@host` remote
    mentions parse correctly but the lookup falls back to a literal text
    span — full webfinger-driven remote-mention import lands with a later
    slice.
  * Newlines become `<br>` (Pixelfed style). No paragraph wrapping yet.
  * No language detection.
  """

  alias Angler.Profiles
  alias Angler.Profiles.Profile

  @mention_re ~r/(?<![A-Za-z0-9_])@([A-Za-z0-9._-]+)(?:@([A-Za-z0-9.-]+))?/u
  @hashtag_re ~r/(?<![A-Za-z0-9_])#([\p{L}\p{N}_]+)/u
  @url_re ~r{https?://[^\s<>"]+}u

  @type token ::
          {:text, String.t()}
          | {:mention, String.t(), String.t() | nil,
             %{username: String.t(), profile: Profile.t() | nil}}
          | {:hashtag, String.t(), %{name: String.t()}}
          | {:url, String.t(), %{url: String.t()}}

  @type result :: %{
          html: String.t(),
          mention_profile_ids: [integer()],
          mention_usernames: [String.t()],
          hashtag_names: [String.t()]
        }

  @doc """
  Tokenize + render `text` into HTML.

  Returns `%{html, mention_profile_ids, mention_usernames, hashtag_names}`.
  """
  @spec render(String.t()) :: result()
  def render(text) when is_binary(text) do
    tokens = tokenize(text)

    html = tokens |> Enum.map(&render_token/1) |> IO.iodata_to_binary()

    mention_profile_ids =
      tokens
      |> Enum.flat_map(fn
        {:mention, _, _, %{profile: %Profile{id: id}}} -> [id]
        _ -> []
      end)
      |> Enum.uniq()

    mention_usernames =
      tokens
      |> Enum.flat_map(fn
        {:mention, _, _, %{username: u}} -> [u]
        _ -> []
      end)
      |> Enum.uniq()

    hashtag_names =
      tokens
      |> Enum.flat_map(fn
        {:hashtag, _, %{name: n}} -> [n]
        _ -> []
      end)
      |> Enum.uniq()

    %{
      html: html,
      mention_profile_ids: mention_profile_ids,
      mention_usernames: mention_usernames,
      hashtag_names: hashtag_names
    }
  end

  @doc false
  # Public so tests can inspect the token stream.
  def tokenize(text) when is_binary(text) do
    matches = collect_matches(text) |> dedupe_overlapping()

    matches
    |> List.foldl({[], 0}, fn {start, len, builder}, {acc, pos} ->
      pre = if start > pos, do: [{:text, binary_part(text, pos, start - pos)} | acc], else: acc

      slice = binary_part(text, start, len)
      tok = builder.(slice)
      {[tok | pre], start + len}
    end)
    |> emit_tail(text)
  end

  defp emit_tail({acc, pos}, text) do
    if pos < byte_size(text) do
      [{:text, binary_part(text, pos, byte_size(text) - pos)} | acc]
    else
      acc
    end
    |> Enum.reverse()
  end

  defp collect_matches(text) do
    mentions =
      Regex.scan(@mention_re, text, return: :index, capture: :all)
      |> Enum.map(fn
        [{start, len}, _user_match, _domain_match] ->
          slice = binary_part(text, start, len)
          [_, username | rest] = Regex.run(@mention_re, slice, capture: :all)

          domain =
            case rest do
              [d] when d != "" -> d
              _ -> nil
            end

          {start, len, fn _slice -> mention_token(username, domain) end}

        [{start, len}, _user_match] ->
          slice = binary_part(text, start, len)
          [_, username] = Regex.run(@mention_re, slice, capture: :all)
          {start, len, fn _slice -> mention_token(username, nil) end}
      end)

    hashtags =
      Regex.scan(@hashtag_re, text, return: :index, capture: :all)
      |> Enum.map(fn [{start, len}, _name_match] ->
        slice = binary_part(text, start, len)
        [_, name] = Regex.run(@hashtag_re, slice, capture: :all)

        {start, len,
         fn _slice ->
           {:hashtag, "#" <> name, %{name: String.downcase(name)}}
         end}
      end)

    urls =
      Regex.scan(@url_re, text, return: :index)
      |> Enum.map(fn [{start, len}] ->
        url = binary_part(text, start, len)
        {start, len, fn _slice -> {:url, url, %{url: url}} end}
      end)

    (mentions ++ hashtags ++ urls)
    |> Enum.sort_by(fn {start, _, _} -> start end)
  end

  # If two regexes claim overlapping ranges (e.g., `#tag` inside `https://…/#tag`),
  # the URL wins because URL matches start earlier.
  defp dedupe_overlapping(matches) do
    Enum.reduce(matches, [], fn {start, _len, _} = m, acc ->
      case acc do
        [{ps, pl, _} | _] when start < ps + pl -> acc
        _ -> [m | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp mention_token(username, domain) do
    profile =
      case domain do
        nil -> Profiles.get_local_by_username(username)
        _ -> nil
      end

    raw =
      case domain do
        nil -> "@" <> username
        d -> "@" <> username <> "@" <> d
      end

    {:mention, raw, domain, %{username: username, profile: profile}}
  end

  ## Render

  defp render_token({:text, t}) do
    t |> escape_html() |> nl_to_br()
  end

  defp render_token({:mention, raw, _domain, %{profile: %Profile{} = profile}}) do
    href = Profiles.url(profile)

    ~s(<span class="h-card"><a href="#{href}" class="u-url mention">) <>
      escape_html(raw) <> ~s(</a></span>)
  end

  defp render_token({:mention, raw, _domain, %{profile: nil}}) do
    # Unresolved (likely remote) mention — emit as plain text rather than a
    # broken link. Re-link on the second pass once the profile resolves.
    escape_html(raw)
  end

  defp render_token({:hashtag, raw, %{name: name}}) do
    href = AnglerWeb.Endpoint.url() <> "/tags/" <> name

    ~s(<a href="#{href}" class="mention hashtag" rel="tag">) <>
      escape_html(raw) <> ~s(</a>)
  end

  defp render_token({:url, _, %{url: url}}) do
    ~s(<a href="#{escape_html(url)}" rel="nofollow noopener" target="_blank">) <>
      escape_html(url) <> ~s(</a>)
  end

  defp escape_html(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp nl_to_br(s) when is_binary(s) do
    String.replace(s, "\n", "<br>")
  end
end
