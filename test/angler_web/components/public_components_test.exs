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
end
