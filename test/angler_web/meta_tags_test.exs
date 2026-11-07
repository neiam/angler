defmodule AnglerWeb.MetaTagsTest do
  @moduledoc "Link-preview tags on the first (dead) render, the one unfurlers fetch."

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Statuses

  setup do
    {:ok, %{profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{alice: alice}
  end

  defp meta(html, attr, name) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(meta[#{attr}="#{name}"]))
    |> LazyHTML.attribute("content")
    |> List.first()
  end

  defp og(html, name), do: meta(html, "property", "og:" <> name)
  defp twitter(html, name), do: meta(html, "name", "twitter:" <> name)

  defp photo_post(alice, attrs) do
    asset = photo_asset!(alice)

    {:ok, s} =
      Statuses.create_local(
        alice,
        Map.merge(%{"visibility" => "public", "media_ids" => [asset.id]}, attrs)
      )

    {s, asset}
  end

  test "a post previews as its photo, author and caption", %{conn: conn, alice: alice} do
    {s, asset} = photo_post(alice, %{"status" => "Golden hour at the pier &amp; #sunset"})

    html = conn |> get(~p"/p/alice/#{s.id}") |> html_response(200)

    assert og(html, "type") == "article"
    assert og(html, "title") =~ "@alice"
    assert og(html, "description") =~ "Golden hour at the pier"
    assert og(html, "url") == AnglerWeb.Endpoint.url() <> "/p/alice/#{s.id}"
    assert og(html, "image") == asset.remote_url
    assert twitter(html, "card") == "summary_large_image"
    assert meta(html, "property", "article:published_time")
  end

  test "a sensitive post keeps its photo out of the preview", %{conn: conn, alice: alice} do
    {s, _} =
      photo_post(alice, %{"status" => "hidden", "sensitive" => true, "spoiler_text" => "Spiders"})

    html = conn |> get(~p"/p/alice/#{s.id}") |> html_response(200)

    refute og(html, "image")
    assert og(html, "description") == "CW: Spiders"
    assert twitter(html, "card") == "summary"
  end

  test "a profile previews as its avatar and counts", %{conn: conn} do
    html = conn |> get(~p"/@alice") |> html_response(200)

    assert og(html, "type") == "profile"
    assert og(html, "title") =~ "@alice"
    assert og(html, "description") =~ "posts"
    assert og(html, "url") == AnglerWeb.Endpoint.url() <> "/@alice"
    assert meta(html, "property", "profile:username") == "alice"
  end

  test "a tag previews with its latest photo", %{conn: conn, alice: alice} do
    {_, asset} = photo_post(alice, %{"status" => "#harbour"})

    html = conn |> get(~p"/tags/harbour") |> html_response(200)

    assert og(html, "title") == "#harbour"
    assert og(html, "image") == asset.remote_url
  end

  test "other pages fall back to the server's title and description", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert og(html, "title") == Angler.Instance.title()
    assert og(html, "description") == Angler.Instance.short_description()
    assert og(html, "site_name") == Angler.Instance.title()

    html = conn |> get(~p"/site/help") |> html_response(200)
    assert og(html, "title") == "Help"
    assert og(html, "url") == AnglerWeb.Endpoint.url() <> "/site/help"
  end
end
