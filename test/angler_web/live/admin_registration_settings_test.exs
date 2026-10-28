defmodule AnglerWeb.AdminRegistrationSettingsTest do
  @moduledoc "Admin-editable registration settings and curated reply templates."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Captcha
  alias Angler.CuratedRegistrations
  alias Angler.CuratedRegistrations.Workers.SendEmail
  alias Angler.Instance

  setup do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "boss", email: "boss@example.com", password: "verysecret123"},
        approved: true
      )

    {:ok, user} = Accounts.set_admin(user, true)
    %{conn: Plug.Test.init_test_session(build_conn(), %{user_id: user.id})}
  end

  test "saving overrides env; a blank secret keeps the saved one; reset drops them", %{conn: conn} do
    refute Instance.curated_registration_enabled?()
    refute Captcha.enabled?()

    {:ok, view, _} = live(conn, ~p"/admin")

    params = %{
      "curated_enabled" => "true",
      "curated_only_on_closed" => "false",
      "captcha_enabled" => "true",
      "captcha_driver" => "turnstile",
      "captcha_sitekey" => "site",
      "captcha_secret" => "shh",
      "cap_endpoint" => "",
      "active_login" => "false",
      "active_register" => "true",
      "active_curated_register" => "true",
      "active_forgot_password" => "true"
    }

    view |> form("#registration-form", %{"registration" => params}) |> render_submit()

    assert Instance.curated_registration_enabled?()
    assert Instance.curated_config(:only_enabled_on_closed_reg, true) == false
    assert Captcha.driver() == :turnstile
    assert Captcha.active_on?(:register)
    refute Captcha.active_on?(:login)

    view
    |> form("#registration-form", %{"registration" => Map.put(params, "captcha_secret", "")})
    |> render_submit()

    assert Captcha.setting(:secret) == "shh"

    view |> element("#reset-registration") |> render_click()
    refute Instance.curated_registration_enabled?()
    refute Captcha.enabled?()
  end

  test "templates: create, then fill a review message from one", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/curated-onboarding/templates")
    assert has_element?(view, "#templates-empty")

    view
    |> form("#template-form", %{
      "template" => %{
        "name" => "More info",
        "content" => "Could you tell us a bit more about your photography?",
        "is_active" => "true"
      }
    })
    |> render_submit()

    [t] = CuratedRegistrations.list_templates()
    assert has_element?(view, "#template-#{t.id}")

    # Too short content is refused.
    view
    |> form("#template-form", %{"template" => %{"name" => "x", "content" => "hi"}})
    |> render_submit()

    assert length(CuratedRegistrations.list_templates()) == 1

    Application.put_env(:angler, :curated_registration, enabled: true)
    on_exit(fn -> Application.delete_env(:angler, :curated_registration) end)

    {:ok, _} =
      CuratedRegistrations.submit(%{
        "username" => "newbie",
        "email" => "newbie@example.com",
        "password" => "verysecret123",
        "password_confirmation" => "verysecret123",
        "reason_to_join" => "I take a lot of photos of birds and want to share them.",
        "agree" => "true"
      })

    job =
      Enum.find(all_enqueued(worker: SendEmail), &(&1.args["text"] =~ "/auth/sign_up/confirm"))

    [url] = Regex.run(~r{https?://\S+/auth/sign_up/confirm\S*}, job.args["text"])
    %{"sid" => sid, "code" => code} = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    {:ok, r} = CuratedRegistrations.confirm_email(sid, code)

    {:ok, review, _} = live(conn, ~p"/admin/curated-onboarding/#{r.id}")

    html =
      review
      |> element("#details-template")
      |> render_change(%{
        "_target" => ["details_template"],
        "details_template" => Integer.to_string(t.id)
      })

    assert html =~ "tell us a bit more about your photography"

    view |> element("#delete-template-#{t.id}") |> render_click()
    assert CuratedRegistrations.list_templates() == []
  end
end
