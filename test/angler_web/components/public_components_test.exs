defmodule AnglerWeb.PublicComponentsTest do
  use AnglerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AnglerWeb.PublicComponents

  defp status(account) do
    %{
      "id" => "1",
      "account" => account,
      "content" => "hello",
      "media_attachments" => [],
      "created_at" => "2026-01-01T00:00:00Z"
    }
  end

  test "post_card links a local author to the in-app profile route" do
    account = %{
      "username" => "alice",
      "acct" => "alice",
      "display_name" => "Alice",
      "avatar" => "",
      "url" => "https://local.test/@alice"
    }

    html = render_component(&PublicComponents.post_card/1, id: "post-1", status: status(account))

    assert html =~ ~s(href="/@alice")
    refute html =~ ~s(href="https://local.test/@alice")
  end

  test "post_card links a remote author to the cached /@acct page, not straight out" do
    account = %{
      "username" => "bob",
      "acct" => "bob@remote.test",
      "display_name" => "Bob",
      "avatar" => "",
      "url" => "https://remote.test/@bob"
    }

    html = render_component(&PublicComponents.post_card/1, id: "post-2", status: status(account))

    # Full acct is preserved (URL-encoded @) so the remote profile resolves;
    # the name must not link out to the origin — that lives on the profile page.
    assert html =~ "/@bob%40remote.test"
    refute html =~ ~s(href="https://remote.test/@bob")
  end

  test "photos open full size in the lightbox; videos keep their player" do
    media = [
      %{
        "id" => "10",
        "type" => "image",
        "url" => "https://cdn.test/full.jpg",
        "preview_url" => "https://cdn.test/thumb.jpg",
        "description" => "a heron"
      },
      %{"id" => "11", "type" => "video", "url" => "https://cdn.test/clip.mp4"}
    ]

    account = %{"username" => "alice", "acct" => "alice", "avatar" => ""}
    status = %{status(account) | "media_attachments" => media}

    doc =
      render_component(&PublicComponents.post_card/1, id: "post-3", status: status)
      |> LazyHTML.from_fragment()

    [tile] = doc |> LazyHTML.query("[data-lightbox-group] #media-10") |> Enum.to_list()
    assert LazyHTML.attribute(tile, "data-lightbox-src") == ["https://cdn.test/full.jpg"]
    assert LazyHTML.attribute(tile, "data-lightbox-alt") == ["a heron"]

    assert tile |> LazyHTML.query("img") |> LazyHTML.attribute("src") == [
             "https://cdn.test/thumb.jpg"
           ]

    assert doc |> LazyHTML.query("[data-lightbox-src]") |> Enum.count() == 1
    assert doc |> LazyHTML.query("video") |> Enum.count() == 1
  end
end
