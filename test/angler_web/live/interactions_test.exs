defmodule AnglerWeb.LiveInteractionsTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Likes.Like
  alias Angler.Reblogs.Reblog
  alias Angler.Repo
  alias Angler.Statuses

  setup do
    {:ok, %{profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, %{user: bob_user, profile: bob}} =
      Accounts.register(%{username: "bob", email: "bob@example.com", password: "verysecret123"})

    {:ok, status} = Statuses.create_local(alice, %{"status" => "hello world"})

    conn = Plug.Test.init_test_session(build_conn(), %{user_id: bob_user.id})
    %{conn: conn, alice: alice, bob: bob, status: status}
  end

  describe "feed (IndexLive)" do
    test "logged-in user sees interactive buttons; anonymous does not", ctx do
      {:ok, anon, _} = live(build_conn(), ~p"/")
      refute has_element?(anon, "button[phx-click=favourite][phx-value-id='#{ctx.status.id}']")

      {:ok, lv, _} = live(ctx.conn, ~p"/")
      assert has_element?(lv, "button[phx-click=favourite][phx-value-id='#{ctx.status.id}']")
    end

    test "favouriting from the feed records a like and updates the count", ctx do
      {:ok, lv, _} = live(ctx.conn, ~p"/")

      html =
        lv
        |> element("button[phx-click=favourite][phx-value-id='#{ctx.status.id}']")
        |> render_click()

      assert html =~ "text-error"
      assert Repo.get_by(Like, profile_id: ctx.bob.id, status_id: ctx.status.id)

      # Toggle off.
      lv
      |> element("button[phx-click=favourite][phx-value-id='#{ctx.status.id}']")
      |> render_click()

      refute Repo.get_by(Like, profile_id: ctx.bob.id, status_id: ctx.status.id)
    end

    test "reblogging from the feed records a reblog", ctx do
      {:ok, lv, _} = live(ctx.conn, ~p"/")

      lv
      |> element("button[phx-click=reblog][phx-value-id='#{ctx.status.id}']")
      |> render_click()

      assert Repo.get_by(Reblog, profile_id: ctx.bob.id, status_id: ctx.status.id)
    end
  end

  describe "permalink (StatusLive)" do
    test "shows comments and lets a logged-in user favourite the post", ctx do
      {:ok, reply} =
        Statuses.create_local(ctx.alice, %{
          "status" => "a thoughtful reply",
          "in_reply_to_id" => ctx.status.id
        })

      {:ok, lv, html} = live(ctx.conn, ~p"/p/alice/#{ctx.status.id}")
      assert html =~ "a thoughtful reply"
      assert html =~ "comment"
      assert has_element?(lv, "#comment-#{reply.id}")

      lv
      |> element("button[phx-click=favourite][phx-value-id='#{ctx.status.id}']")
      |> render_click()

      assert Repo.get_by(Like, profile_id: ctx.bob.id, status_id: ctx.status.id)
    end

    test "anonymous sees the comment but no action buttons", ctx do
      {:ok, _} =
        Statuses.create_local(ctx.alice, %{
          "status" => "public reply",
          "in_reply_to_id" => ctx.status.id
        })

      {:ok, lv, html} = live(build_conn(), ~p"/p/alice/#{ctx.status.id}")
      assert html =~ "public reply"
      refute has_element?(lv, "button[phx-click=favourite]")
    end

    test "logged-in user can post a reply, which appears and bumps the count", ctx do
      {:ok, lv, _} = live(ctx.conn, ~p"/p/alice/#{ctx.status.id}")

      html =
        lv
        |> form("form[phx-submit=reply]", reply: %{body: "great shot!"})
        |> render_submit()

      assert html =~ "great shot!"
      assert html =~ "1 comment"

      reply = Repo.get_by(Statuses.Status, in_reply_to_id: ctx.status.id)
      assert reply
      assert reply.profile_id == ctx.bob.id
    end

    test "anonymous gets a login prompt instead of the composer", ctx do
      {:ok, lv, html} = live(build_conn(), ~p"/p/alice/#{ctx.status.id}")
      refute has_element?(lv, "form[phx-submit=reply]")
      assert html =~ "to join the conversation"
    end

    test "inline composer posts a nested reply under a specific comment", ctx do
      {:ok, comment} =
        Statuses.create_local(ctx.alice, %{
          "status" => "first comment",
          "in_reply_to_id" => ctx.status.id
        })

      {:ok, lv, _} = live(ctx.conn, ~p"/p/alice/#{ctx.status.id}")

      # No inline composer until the comment's Reply toggle is clicked.
      refute has_element?(lv, "input[name='reply[parent_id]'][value='#{comment.id}']")

      lv
      |> element("button[phx-click=toggle_reply][phx-value-id='#{comment.id}']")
      |> render_click()

      assert has_element?(lv, "input[name='reply[parent_id]'][value='#{comment.id}']")

      lv
      |> form("#reply-form-#{comment.id}", reply: %{body: "nested answer"})
      |> render_submit()

      nested = Repo.get_by(Statuses.Status, in_reply_to_id: comment.id)
      assert nested
      assert nested.caption == "nested answer"
      assert nested.profile_id == ctx.bob.id

      # Both the parent comment and the nested reply are now on the page.
      assert has_element?(lv, "#comment-#{comment.id}")
      assert has_element?(lv, "#comment-#{nested.id}")
    end
  end

  describe "profile page (ProfileLive)" do
    test "logged-in user can favourite a post from the profile", ctx do
      {:ok, lv, _} = live(ctx.conn, ~p"/@alice")

      lv
      |> element("button[phx-click=favourite][phx-value-id='#{ctx.status.id}']")
      |> render_click()

      assert Repo.get_by(Like, profile_id: ctx.bob.id, status_id: ctx.status.id)
    end
  end
end
