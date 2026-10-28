defmodule AnglerWeb.RegisterProtectionsTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest
  import Angler.CaptchaHelpers

  alias Angler.Auth
  alias Angler.Auth.Workers.SendAppCodeEmail

  setup do
    put_env(:open_registration, true)
    put_env(:registration_approval_required, false)
    :ok
  end

  defp put_env(key, value) do
    previous = Application.get_env(:angler, key)
    Application.put_env(:angler, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:angler, key),
        else: Application.put_env(:angler, key, previous)
    end)
  end

  defp honeypot_name(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#register-hp input")
    |> LazyHTML.attribute("name")
    |> hd()
  end

  describe "honeypot" do
    test "a filled trap field is silently dropped", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/register")

      view
      |> form("#register-email-form", %{
        "email" => "bot@example.com",
        honeypot_name(view) => "I am a bot"
      })
      |> render_submit()

      assert has_element?(view, "#register-details-form")
      refute_enqueued(worker: SendAppCodeEmail)
      assert Auth.get_register("bot@example.com") == nil
    end

    test "a too-fast submission is silently dropped", %{conn: conn} do
      put_env(:honeypot, seconds: 60)
      {:ok, view, _} = live(conn, ~p"/register")

      view |> form("#register-email-form", %{"email" => "fast@example.com"}) |> render_submit()

      assert has_element?(view, "#register-details-form")
      refute_enqueued(worker: SendAppCodeEmail)
    end

    test "a person gets the code", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/register")

      view |> form("#register-email-form", %{"email" => "human@example.com"}) |> render_submit()

      assert has_element?(view, "#register-details-form")
      assert_enqueued(worker: SendAppCodeEmail, args: %{"email" => "human@example.com"})
    end
  end

  describe "captcha on register" do
    test "the widget is absent while the captcha is off", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/register")
      refute has_element?(view, "#register-captcha")
    end

    test "an unsolved captcha blocks the code email", %{conn: conn} do
      enable_captcha()
      stub_verify(false)
      {:ok, view, _} = live(conn, ~p"/register")

      assert has_element?(view, "#register-captcha[data-driver=hcaptcha][data-sitekey=site-key]")

      view
      |> form("#register-email-form", %{"email" => "human@example.com"})
      |> render_submit(%{"captcha_token" => "bad"})

      assert has_element?(view, "#register-error")
      refute has_element?(view, "#register-details-form")
      refute_enqueued(worker: SendAppCodeEmail)
    end

    test "a solved captcha lets the email through", %{conn: conn} do
      enable_captcha()
      stub_verify(true)
      {:ok, view, _} = live(conn, ~p"/register")

      view
      |> form("#register-email-form", %{"email" => "human@example.com"})
      |> render_submit(%{"captcha_token" => "good"})

      assert_received {:captcha_verify, _conn, body}
      assert URI.decode_query(body)["response"] == "good"
      assert has_element?(view, "#register-details-form")
    end
  end

  describe "minimum age" do
    test "the account needs the age confirmation", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/register")
      view |> form("#register-email-form", %{"email" => "kid@example.com"}) |> render_submit()
      {:ok, code, _} = Auth.issue_code("kid@example.com")

      details = %{
        "code" => code,
        "username" => "kiddo",
        "password" => "verysecret123",
        "name" => ""
      }

      view |> form("#register-details-form", details) |> render_submit()
      assert has_element?(view, "#register-error", "16")
      assert Angler.Accounts.get_by_email("kid@example.com") == nil

      assert {:error, {:live_redirect, %{to: "/login"}}} =
               view
               |> form("#register-details-form", Map.put(details, "agecheck", "true"))
               |> render_submit()

      assert Angler.Accounts.get_by_email("kid@example.com")
    end
  end

  describe "captcha on login" do
    setup do
      {:ok, _} =
        Angler.Accounts.register(
          %{username: "alice", email: "alice@example.com", password: "verysecret123"},
          approved: true
        )

      :ok
    end

    test "the live check refuses an unsolved captcha", %{conn: conn} do
      enable_captcha()
      stub_verify(false)
      {:ok, view, _} = live(conn, ~p"/login")

      assert has_element?(view, "#login-captcha")

      view
      |> form("#login-form", %{"username" => "alice", "password" => "verysecret123"})
      |> render_submit()

      assert has_element?(view, "#login-error")
      refute has_element?(view, "#login-captcha-pass")
    end

    test "a solved captcha hands the native POST a pass", %{conn: conn} do
      enable_captcha()
      stub_verify(true)
      {:ok, view, _} = live(conn, ~p"/login")

      form =
        form(view, "#login-form", %{"username" => "alice", "password" => "verysecret123"})

      render_submit(form, %{"captcha_token" => "good"})
      assert has_element?(view, "#login-captcha-pass")

      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id)
    end

    test "the session POST needs a captcha pass", %{conn: conn} do
      enable_captcha()
      stub_verify(false)

      conn =
        post(conn, ~p"/session/login", %{"username" => "alice", "password" => "verysecret123"})

      assert redirected_to(conn) =~ "/login"
      refute get_session(conn, :user_id)
    end

    test "the plain session form redirects to the captcha-capable page", %{conn: conn} do
      enable_captcha()
      conn = get(conn, ~p"/session/login?next=/settings/profile")
      assert redirected_to(conn) == "/login?next=%2Fsettings%2Fprofile"
    end
  end

  describe "captcha on forgot password" do
    test "an unsolved captcha sends nothing", %{conn: conn} do
      enable_captcha()
      stub_verify(false)
      {:ok, view, _} = live(conn, ~p"/forgot-password")

      view
      |> form("#forgot-password-form", %{"email" => "a@example.com"})
      |> render_submit()

      assert has_element?(view, "#forgot-password-error")
    end
  end
end
