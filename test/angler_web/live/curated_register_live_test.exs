defmodule AnglerWeb.CuratedRegisterLiveTest do
  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest
  import Angler.CaptchaHelpers

  alias Angler.Accounts
  alias Angler.CuratedRegistrations
  alias Angler.CuratedRegistrations.Workers.SendEmail
  alias Angler.Repo

  @application %{
    "username" => "newbie",
    "email" => "newbie@example.com",
    "password" => "verysecret123",
    "password_confirmation" => "verysecret123",
    "reason_to_join" => "I take a lot of photos of birds and want to share them.",
    "agree" => "true"
  }

  setup do
    put_env(:open_registration, false)
    put_env(:curated_registration, enabled: true)
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

  defp adult_birthdate, do: Date.utc_today() |> Date.shift(year: -30) |> Date.to_iso8601()

  defp emailed_link(to, path) do
    job =
      all_enqueued(worker: SendEmail)
      |> Enum.filter(&(&1.args["to"] == to and &1.args["text"] =~ path))
      |> hd()

    [url] = Regex.run(~r{https?://\S+#{Regex.escape(path)}\S*}, job.args["text"])
    url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
  end

  defp verified_application do
    {:ok, r} = CuratedRegistrations.submit(@application)
    %{"sid" => sid, "code" => code} = emailed_link(r.email, "/auth/sign_up/confirm")
    {:ok, r} = CuratedRegistrations.confirm_email(sid, code)
    r
  end

  defp admin_conn do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "boss", email: "boss@example.com", password: "verysecret123"},
        approved: true
      )

    {:ok, user} = Accounts.set_admin(user, true)
    {Plug.Test.init_test_session(build_conn(), %{user_id: user.id}), user}
  end

  describe "gating" do
    test "closed /register forwards to the application form", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/sign_up"}}} = live(conn, ~p"/register")
    end

    test "the form is off unless curated registration is on", %{conn: conn} do
      put_env(:curated_registration, enabled: false)
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/auth/sign_up")
    end

    test "with open registration it is off by default", %{conn: conn} do
      put_env(:open_registration, true)
      assert {:error, {:live_redirect, %{to: "/register"}}} = live(conn, ~p"/auth/sign_up")

      put_env(:curated_registration, enabled: true, only_enabled_on_closed_reg: false)
      assert {:ok, _view, _} = live(conn, ~p"/auth/sign_up")
    end

    test "the landing page offers the application", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#index-apply")
    end
  end

  describe "applying" do
    test "under-age applicants are turned away", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/auth/sign_up")
      young = Date.utc_today() |> Date.shift(year: -12) |> Date.to_iso8601()

      view |> form("#curated-age-form", %{"age" => %{"birthdate" => young}}) |> render_submit()

      assert has_element?(view, "#curated-error")
      refute has_element?(view, "#curated-apply-form")
    end

    test "an adult submits the application and is asked to confirm", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/auth/sign_up")

      view
      |> form("#curated-age-form", %{"age" => %{"birthdate" => adult_birthdate()}})
      |> render_submit()

      assert has_element?(view, "#curated-apply-form")
      assert has_element?(view, "#curated-hp")

      view
      |> form("#curated-apply-form", %{"curated_register" => @application})
      |> render_submit()

      assert has_element?(view, "#curated-sent")
      assert [%{username: "newbie"}] = CuratedRegistrations.list("all")
    end

    test "validation errors keep the form", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/auth/sign_up")

      view
      |> form("#curated-age-form", %{"age" => %{"birthdate" => adult_birthdate()}})
      |> render_submit()

      view
      |> form("#curated-apply-form", %{
        "curated_register" => %{@application | "reason_to_join" => "too short"}
      })
      |> render_submit()

      assert has_element?(view, "#curated-apply-form")
      assert CuratedRegistrations.list("all") == []
    end

    test "the captcha guards the application when active", %{conn: conn} do
      enable_captcha()
      stub_verify(false)
      {:ok, view, _} = live(conn, ~p"/auth/sign_up")

      view
      |> form("#curated-age-form", %{"age" => %{"birthdate" => adult_birthdate()}})
      |> render_submit()

      assert has_element?(view, "#curated-captcha")

      view
      |> form("#curated-apply-form", %{"curated_register" => @application})
      |> render_submit()

      assert has_element?(view, "#curated-error")
      assert CuratedRegistrations.list("all") == []
    end
  end

  describe "follow-up pages" do
    test "the emailed link confirms the email", %{conn: conn} do
      {:ok, r} = CuratedRegistrations.submit(@application)
      %{"sid" => sid, "code" => code} = emailed_link(r.email, "/auth/sign_up/confirm")

      {:ok, view, _} = live(conn, ~p"/auth/sign_up/confirm?#{[sid: sid, code: code]}")
      view |> element("#curated-confirm-form") |> render_submit()

      assert has_element?(view, "#curated-confirmed")
      assert Repo.reload!(r).email_verified_at
    end

    test "a bad link says so", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/auth/sign_up/confirm?#{[sid: "1", code: "nope"]}")
      view |> element("#curated-confirm-form") |> render_submit()
      assert has_element?(view, "#curated-error")
    end

    test "the confirmation link can be resent", %{conn: conn} do
      {:ok, _} = CuratedRegistrations.submit(@application)
      {:ok, view, _} = live(conn, ~p"/auth/sign_up/resend-confirmation")

      view
      |> form("#curated-resend-form", %{"resend" => %{"email" => "newbie@example.com"}})
      |> render_submit()

      assert has_element?(view, "#curated-resent")
    end

    test "the applicant answers an admin's request", %{conn: conn} do
      r = verified_application()
      {_, boss} = admin_conn()
      {:ok, _} = CuratedRegistrations.request_details(r, boss, "Which birds, exactly?")
      link = emailed_link(r.email, "/auth/sign_up/concierge")

      {:ok, view, _} = live(conn, ~p"/auth/sign_up/concierge?#{link}")
      assert has_element?(view, "#curated-admin-message", "Which birds")

      view
      |> form("#curated-concierge-form", %{
        "concierge" => %{"email" => "newbie@example.com", "response" => "Herons and egrets."}
      })
      |> render_submit()

      assert has_element?(view, "#curated-response-sent")
      assert Repo.reload!(r).user_has_responded
    end

    test "an invalid request link shows a notice", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/auth/sign_up/concierge?#{[sid: "1", id: "1", code: "x"]}")
      assert has_element?(view, "#curated-request-invalid")
    end
  end

  describe "admin review" do
    test "non-admins can't reach the queue", %{conn: conn} do
      assert {:error, {:redirect, _}} = live(conn, ~p"/admin/curated-onboarding")
    end

    test "the queue lists verified applications by filter" do
      r = verified_application()
      {conn, _} = admin_conn()

      {:ok, view, _} = live(conn, ~p"/admin/curated-onboarding")
      assert has_element?(view, "#records-#{r.id}")

      view |> element("#curated-filter-approved") |> render_click()
      assert has_element?(view, "#curated-empty")
      refute has_element?(view, "#records-#{r.id}")
    end

    test "approving creates the account" do
      r = verified_application()
      {conn, _} = admin_conn()

      {:ok, view, _} = live(conn, ~p"/admin/curated-onboarding/#{r.id}")
      assert has_element?(view, "#curated-reason", "birds")

      view |> element("#curated-approve") |> render_click()

      refute has_element?(view, "#curated-approve")
      assert {:ok, _} = Accounts.authenticate("newbie", "verysecret123")
    end

    test "rejecting with a note emails it" do
      r = verified_application()
      {conn, _} = admin_conn()

      {:ok, view, _} = live(conn, ~p"/admin/curated-onboarding/#{r.id}")

      view
      |> form("#curated-reject-form", %{
        "reject" => %{"message" => "Not a fit right now.", "notify" => "true"}
      })
      |> render_submit()

      assert Repo.reload!(r).is_rejected
      assert Enum.any?(all_enqueued(worker: SendEmail), &(&1.args["text"] =~ "Not a fit"))
    end

    test "requesting details adds to the thread" do
      r = verified_application()
      {conn, _} = admin_conn()

      {:ok, view, _} = live(conn, ~p"/admin/curated-onboarding/#{r.id}")

      view
      |> form("#curated-details-form", %{"details" => %{"message" => "Tell us more please."}})
      |> render_submit()

      assert has_element?(view, "#curated-thread", "Tell us more")
      assert Repo.reload!(r).is_awaiting_more_info
    end
  end

  describe "instance API" do
    test "reports curated registration as approval required", %{conn: conn} do
      put_env(:registration_approval_required, false)

      assert %{"registrations" => false, "approval_required" => true} =
               conn |> get(~p"/api/v1/instance") |> json_response(200)

      assert %{"registrations" => %{"enabled" => false, "approval_required" => true}} =
               build_conn() |> get(~p"/api/v2/instance") |> json_response(200)

      assert %{"signup" => %{"curated" => true}} =
               build_conn() |> get(~p"/api/v2.1/config") |> json_response(200)

      assert %{"openRegistrations" => false} =
               build_conn() |> get(~p"/api/nodeinfo/2.0.json") |> json_response(200)
    end
  end
end
