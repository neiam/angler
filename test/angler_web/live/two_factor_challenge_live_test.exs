defmodule AnglerWeb.TwoFactorChallengeLiveTest do
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Accounts.TwoFactor

  setup %{conn: conn} do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    secret = TwoFactor.new_secret()
    {:ok, _recovery_codes} = TwoFactor.enable(user, secret, NimbleTOTP.verification_code(secret))
    on_exit(fn -> Angler.RateLimit.reset({:two_factor, user.id}) end)

    %{conn: init_test_session(conn, %{two_factor_user_id: user.id}), secret: secret}
  end

  test "a right code passes", %{conn: conn, secret: secret} do
    {:ok, view, _} = live(conn, ~p"/login/two-factor")

    assert {:error, {:redirect, %{to: "/login/two-factor/complete?" <> _}}} =
             view
             |> element("#two-factor-form")
             |> render_submit(%{"code" => NimbleTOTP.verification_code(secret)})
  end

  test "after five wrong codes even the right one is refused", %{conn: conn, secret: secret} do
    {:ok, view, _} = live(conn, ~p"/login/two-factor")

    for _ <- 1..5 do
      view |> element("#two-factor-form") |> render_submit(%{"code" => "000000"})
    end

    html =
      view
      |> element("#two-factor-form")
      |> render_submit(%{"code" => NimbleTOTP.verification_code(secret)})

    assert html =~ "Too many attempts"
  end
end
