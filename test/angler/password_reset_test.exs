defmodule Angler.PasswordResetTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Accounts.{PasswordResetToken, User}
  alias Angler.Auth.Workers.SendPasswordResetEmail
  alias Angler.Repo

  defp user!(opts \\ []) do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: opts[:username] || "alice",
        email: opts[:email] || "alice@example.com",
        password: opts[:password] || "verysecret123"
      })

    user
  end

  defp token_from_email do
    [job] = all_enqueued(worker: SendPasswordResetEmail)
    job.args["url"] |> String.split("/reset-password/") |> List.last()
  end

  describe "deliver_password_reset/1" do
    test "creates a token and enqueues the email for a known address" do
      user!()
      assert :ok = Accounts.deliver_password_reset("alice@example.com")
      assert Repo.aggregate(PasswordResetToken, :count) == 1
      assert_enqueued(worker: SendPasswordResetEmail)
    end

    test "is silent for an unknown address (no token, no enumeration)" do
      assert :ok = Accounts.deliver_password_reset("nobody@example.com")
      assert Repo.aggregate(PasswordResetToken, :count) == 0
      refute_enqueued(worker: SendPasswordResetEmail)
    end
  end

  describe "token verification + reset" do
    test "full flow: emailed token resets the password and is then consumed" do
      user = user!()
      :ok = Accounts.deliver_password_reset("alice@example.com")
      token = token_from_email()

      assert %User{id: id} = Accounts.get_user_by_reset_token(token)
      assert id == user.id

      assert {:ok, _} = Accounts.reset_password(user, %{password: "newpassword456"})

      assert Accounts.get_user_by_reset_token(token) == nil
      assert {:ok, _} = Accounts.authenticate("alice", "newpassword456")
      assert :error = Accounts.authenticate("alice", "verysecret123")
    end

    test "expired token is rejected" do
      user = user!()
      raw = :crypto.strong_rand_bytes(32)
      encoded = Base.url_encode64(raw, padding: false)
      hash = :crypto.hash(:sha256, raw)

      tok = Repo.insert!(%PasswordResetToken{token: hash, user_id: user.id})
      old = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

      Repo.update_all(from(t in PasswordResetToken, where: t.id == ^tok.id),
        set: [inserted_at: old]
      )

      assert Accounts.get_user_by_reset_token(encoded) == nil
    end

    test "garbage token is rejected" do
      assert Accounts.get_user_by_reset_token("not-a-real-token") == nil
    end
  end

  describe "web flow" do
    test "forgot-password sends and shows a neutral confirmation", %{conn: conn} do
      user!()
      {:ok, lv, _} = live(conn, ~p"/forgot-password")

      html =
        lv |> form("form", %{"email" => "alice@example.com"}) |> render_submit()

      assert html =~ "reset link is on its way"
      assert_enqueued(worker: SendPasswordResetEmail)
    end

    test "invalid token renders a dead-end", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/reset-password/#{"bogus"}")
      assert html =~ "Reset link invalid"
    end

    test "valid token resets the password and redirects to login", %{conn: conn} do
      user!()
      :ok = Accounts.deliver_password_reset("alice@example.com")
      token = token_from_email()

      {:ok, lv, _} = live(conn, ~p"/reset-password/#{token}")

      lv
      |> form("form", %{
        "password" => "newpassword456",
        "password_confirmation" => "newpassword456"
      })
      |> render_submit()

      assert_redirect(lv, ~p"/login")
      assert {:ok, _} = Accounts.authenticate("alice", "newpassword456")
    end

    test "mismatched confirmation shows an error and does not reset", %{conn: conn} do
      user!()
      :ok = Accounts.deliver_password_reset("alice@example.com")
      token = token_from_email()

      {:ok, lv, _} = live(conn, ~p"/reset-password/#{token}")

      html =
        lv
        |> form("form", %{
          "password" => "newpassword456",
          "password_confirmation" => "different789"
        })
        |> render_submit()

      assert html =~ "Passwords don&#39;t match." or html =~ "Passwords don't match."
      assert {:ok, _} = Accounts.authenticate("alice", "verysecret123")
    end
  end
end
