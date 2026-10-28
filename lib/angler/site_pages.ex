defmodule Angler.SitePages do
  @moduledoc """
  The instance's legal and help pages: terms, privacy, help, community
  guidelines, legal notice, plus the two knowledge-base pages we link to
  from federation docs (licenses, instance actor). Upstream serves these at
  `/site/*`, and the Pixelfed app opens `/e/terms`, `/e/privacy` and
  `/site/help` from Settings.

  Admins paste Markdown for each on `/admin/pages` (upstream
  `/i/admin/settings/pages`). Until they do, a short default stands in, so
  no link 404s. Markdown is rendered with MDEx with raw HTML dropped, so a
  page can't carry scripts.
  """

  import Ecto.Query, warn: false

  alias Angler.Repo
  alias Angler.SitePages.Page

  # {key, path, default title}
  @pages [
    {"terms", "/site/terms", "Terms of Service"},
    {"privacy", "/site/privacy", "Privacy Policy"},
    {"help", "/site/help", "Help"},
    {"community-guidelines", "/site/kb/community-guidelines", "Community Guidelines"},
    {"legal-notice", "/site/legal-notice", "Legal Notice"},
    {"licenses", "/site/kb/licenses", "Media licenses"},
    {"instance-actor", "/site/kb/instance-actor", "Instance actor"}
  ]

  @keys Enum.map(@pages, &elem(&1, 0))

  @doc "Every page: `%{key, path, title, custom?}`, in admin menu order."
  @spec list() :: [map()]
  def list do
    saved = Repo.all(Page) |> Map.new(&{&1.slug, &1})

    for {key, path, title} <- @pages do
      page = saved[key]
      %{key: key, path: path, title: (page && present(page.title)) || title, custom?: page != nil}
    end
  end

  def keys, do: @keys

  @doc "A page by key: its title, Markdown, whether it's admin-written."
  @spec get(String.t()) ::
          %{key: String.t(), title: String.t(), content: String.t(), custom?: boolean()} | nil
  def get(key) when key in @keys do
    {^key, path, default_title} = List.keyfind(@pages, key, 0)

    case Repo.get_by(Page, slug: key) do
      %Page{} = p ->
        %{
          key: key,
          path: path,
          title: present(p.title) || default_title,
          content: p.content,
          custom?: true
        }

      nil ->
        %{key: key, path: path, title: default_title, content: default(key), custom?: false}
    end
  end

  def get(_), do: nil

  @doc "Save a page's title and Markdown."
  @spec put(String.t(), map()) :: {:ok, Page.t()} | {:error, Ecto.Changeset.t()}
  def put(key, attrs) when key in @keys do
    (Repo.get_by(Page, slug: key) || %Page{slug: key})
    |> Page.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Drop the admin's version, back to the default."
  @spec reset(String.t()) :: :ok
  def reset(key) when key in @keys do
    {_, _} = Repo.delete_all(from p in Page, where: p.slug == ^key)
    :ok
  end

  @doc "Markdown to HTML, raw HTML dropped."
  @spec render(String.t()) :: String.t()
  def render(markdown) when is_binary(markdown) do
    MDEx.to_html!(markdown,
      extension: [table: true, strikethrough: true, autolink: true],
      render: [unsafe: false]
    )
  end

  defp present(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp present(_), do: nil

  defp default(key) when key in ["terms", "privacy", "community-guidelines", "legal-notice"] do
    rules =
      case Angler.Instance.rules() do
        [] -> ""
        rules -> "\n\n## Server rules\n\n" <> Enum.map_join(rules, "\n", &("- " <> &1))
      end

    contact =
      case Angler.Instance.contact_email() do
        nil -> ""
        email -> "\n\nQuestions? Contact <#{email}>."
      end

    "The admins of #{Angler.Instance.title()} haven't published this page yet." <>
      rules <> contact
  end

  defp default("help") do
    """
    #{Angler.Instance.title()} runs [Angler](https://github.com/neiam/angler), a server that
    works with the Pixelfed app and Mastodon-compatible apps, and talks to the rest of
    the fediverse.

    - [About this server](/about)
    - [Community guidelines](/site/kb/community-guidelines)
    - [Terms of service](/site/terms) · [Privacy policy](/site/privacy)
    """
  end

  defp default("licenses") do
    """
    Each photo can carry a license, chosen when you post (your default is in
    [profile settings](/settings/profile)). The license says what others may do with
    your work; "All Rights Reserved" means nothing beyond viewing it here. The
    Creative Commons licenses are explained at
    [creativecommons.org/licenses](https://creativecommons.org/licenses/).
    """
  end

  defp default("instance-actor") do
    """
    The instance actor is an account that represents this server itself rather than
    any person. It signs requests the server makes on its own behalf, such as
    fetching posts and profiles from other servers or following relays. It never
    posts, and you can't follow it.
    """
  end
end
