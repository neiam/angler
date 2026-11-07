defmodule AnglerWeb.MetaTags do
  @moduledoc """
  Open Graph and Twitter Card tags, so a link pasted into a messenger or
  another app unfurls into a preview card: photo, author, caption.

  A LiveView sets `:meta` in `mount/3` with one of the builders here
  (`status/1`, `profile/1`, `tag/2`, `page/3`); the root layout renders it
  with `tags/1` on the first (dead) render, which is the one link
  unfurlers fetch. Pages without `:meta` get the server's title and
  description.

  Sensitive posts never put their photo in the preview, and only public
  and unlisted posts get a description at all.
  """
  use Phoenix.Component

  alias Angler.Instance

  @description_max 200

  @doc """
  The preview for a post at `path`: its first photo (or video still) and
  caption. The URL is always ours, even for a post from another server.
  """
  @spec status(map(), String.t()) :: map()
  def status(%{"account" => account} = status, path) do
    shareable? = status["visibility"] in ["public", "unlisted"]
    image = if shareable?, do: photo(status)

    %{
      type: "article",
      title: "#{author(account)} on #{Instance.title()}",
      description: if(shareable?, do: status_description(status)),
      url: AnglerWeb.Endpoint.url() <> path,
      image: image,
      card: if(image, do: "summary_large_image", else: "summary"),
      published: status["created_at"]
    }
  end

  @doc "The preview for a profile page at `path`: avatar, bio, counts."
  @spec profile(map(), String.t()) :: map()
  def profile(account, path) do
    counts =
      "#{account["statuses_count"] || 0} posts · #{account["followers_count"] || 0} followers"

    bio = plain(account["note"])

    avatar =
      if present(account["avatar"]), do: %{url: account["avatar"], alt: author(account)}

    %{
      type: "profile",
      title: author(account),
      description: if(bio, do: counts <> " · " <> bio, else: counts),
      url: AnglerWeb.Endpoint.url() <> path,
      image: avatar,
      card: "summary",
      username: account["username"]
    }
  end

  @doc """
  The preview for a tag page: its latest non-sensitive photo, if the
  first page of `statuses` has one.
  """
  @spec tag(String.t(), [map()]) :: map()
  def tag(name, statuses) do
    image = Enum.find_value(statuses, &photo/1)

    %{
      type: "website",
      title: "##{name}",
      description: "Photos tagged ##{name} on #{Instance.title()}",
      url: AnglerWeb.Endpoint.url() <> "/tags/" <> name,
      image: image,
      card: if(image, do: "summary_large_image", else: "summary")
    }
  end

  @doc "A plain page: a title, a description and its path."
  @spec page(String.t(), String.t() | nil, String.t()) :: map()
  def page(title, description, path) do
    %{
      type: "website",
      title: title,
      description: plain(description),
      url: AnglerWeb.Endpoint.url() <> path,
      card: "summary"
    }
  end

  @doc "Renders the tags; `meta` nil falls back to the server's own."
  attr :meta, :map, default: nil

  def tags(assigns) do
    meta =
      assigns.meta ||
        %{type: "website", title: Instance.title(), description: Instance.short_description()}

    assigns =
      assigns
      |> assign(:m, meta)
      |> assign(:image, meta[:image])
      |> assign(:site, Instance.title())

    ~H"""
    <meta :if={@m[:description]} name="description" content={@m.description} />
    <link :if={@m[:url]} rel="canonical" href={@m.url} />
    <meta property="og:site_name" content={@site} />
    <meta property="og:type" content={@m.type} />
    <meta property="og:title" content={@m.title} />
    <meta :if={@m[:description]} property="og:description" content={@m.description} />
    <meta :if={@m[:url]} property="og:url" content={@m.url} />
    <%= if @image do %>
      <meta property="og:image" content={@image.url} />
      <meta :if={present(@image[:alt])} property="og:image:alt" content={@image.alt} />
      <meta name="twitter:image" content={@image.url} />
      <meta :if={present(@image[:alt])} name="twitter:image:alt" content={@image.alt} />
    <% end %>
    <meta :if={@m[:published]} property="article:published_time" content={@m.published} />
    <meta :if={@m[:username]} property="profile:username" content={@m.username} />
    <meta name="twitter:card" content={@m[:card] || "summary"} />
    <meta name="twitter:title" content={@m.title} />
    <meta :if={@m[:description]} name="twitter:description" content={@m.description} />
    """
  end

  # A post's first photo (or video still), unless the post is sensitive.
  defp photo(%{"sensitive" => true}), do: nil

  defp photo(status) do
    case status["media_attachments"] do
      [m | _] -> %{url: m["preview_url"] || m["url"], alt: m["description"]}
      _ -> nil
    end
  end

  defp status_description(%{"sensitive" => true} = status) do
    case present(status["spoiler_text"]) do
      nil -> "Sensitive content"
      cw -> "CW: " <> cw
    end
  end

  defp status_description(status), do: plain(status["content"])

  defp author(account) do
    name = present(account["display_name"]) || account["username"]
    "#{name} (@#{account["acct"]})"
  end

  # Caption HTML to one line of text, trimmed to a preview-sized length.
  defp plain(nil), do: nil

  defp plain(html) do
    text =
      html
      |> String.replace(~r{<br\s*/?>|</p>}i, " ")
      |> String.replace(~r/<[^>]*>/, "")
      |> String.replace(~w(&amp; &lt; &gt; &quot; &#39; &nbsp;), fn
        "&amp;" -> "&"
        "&lt;" -> "<"
        "&gt;" -> ">"
        "&quot;" -> "\""
        "&#39;" -> "'"
        "&nbsp;" -> " "
      end)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      text == "" ->
        nil

      String.length(text) <= @description_max ->
        text

      true ->
        String.slice(text, 0, @description_max - 1) |> String.trim_trailing() |> Kernel.<>("…")
    end
  end

  defp present(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp present(_), do: nil
end
