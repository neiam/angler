defmodule Angler.CaptchaTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Angler.CaptchaHelpers

  alias Angler.Captcha

  describe "active_on?/1" do
    test "off by default" do
      refute Captcha.active_on?(:register)
      refute Captcha.active_on?(:login)
    end

    test "needs the global switch, keys, and the surface toggle" do
      enable_captcha(active: [login: false])
      assert Captcha.active_on?(:register)
      assert Captcha.active_on?(:curated_register)
      refute Captcha.active_on?(:login)

      enable_captcha(secret: nil)
      refute Captcha.active_on?(:register)

      enable_captcha(enabled: false)
      refute Captcha.active_on?(:register)
    end

    test "cap also needs its endpoint" do
      enable_captcha(driver: "cap")
      refute Captcha.active_on?(:register)

      enable_captcha(driver: "cap", cap_endpoint: "https://cap.example.com/")
      assert Captcha.active_on?(:register)
    end
  end

  describe "widget/0" do
    test "describes the provider script per driver" do
      enable_captcha()

      assert %{driver: "hcaptcha", sitekey: "site-key", script: "https://js.hcaptcha.com/" <> _} =
               Captcha.widget()

      enable_captcha(driver: :turnstile)
      assert Captcha.widget().script =~ "challenges.cloudflare.com/turnstile"

      enable_captcha(driver: :cap, cap_endpoint: "https://cap.example.com")

      assert %{api: "https://cap.example.com/site-key/", script: script} = Captcha.widget()
      assert script =~ "@cap.js/widget@latest"
    end
  end

  describe "verify/2" do
    test "posts the token and secret to hCaptcha's siteverify" do
      enable_captcha()
      stub_verify(true)

      assert Captcha.verify("tok", "203.0.113.9")
      assert_receive {:captcha_verify, conn, body}
      assert conn.host == "api.hcaptcha.com"
      assert conn.request_path == "/siteverify"

      assert URI.decode_query(body) == %{
               "secret" => "s3cret",
               "response" => "tok",
               "remoteip" => "203.0.113.9"
             }
    end

    test "uses Turnstile's endpoint" do
      enable_captcha(driver: :turnstile)
      stub_verify(true)

      assert Captcha.verify("tok")
      assert_receive {:captcha_verify, conn, _}
      assert conn.host == "challenges.cloudflare.com"
      assert conn.request_path == "/turnstile/v0/siteverify"
    end

    test "posts JSON to Cap's {endpoint}/{sitekey}/siteverify" do
      enable_captcha(driver: :cap, cap_endpoint: "https://cap.example.com")
      stub_verify(true)

      assert Captcha.verify("tok")
      assert_receive {:captcha_verify, conn, body}
      assert conn.host == "cap.example.com"
      assert conn.request_path == "/site-key/siteverify"
      assert Jason.decode!(body) == %{"secret" => "s3cret", "response" => "tok"}
    end

    test "rejects a failed or missing token" do
      enable_captcha()
      stub_verify(false)

      refute Captcha.verify("tok")
      refute Captcha.verify("")
      refute Captcha.verify(nil)
    end

    test "fails closed on a provider error unless fail_open" do
      enable_captcha()

      Req.Test.stub(:angler_http, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
      Req.Test.set_req_test_to_shared(self())
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)

      refute Captcha.verify("tok")

      enable_captcha(fail_open: true)
      assert Captcha.verify("tok")
    end
  end

  describe "check/3" do
    test "passes unguarded surfaces without calling out" do
      assert Captcha.check(:register, %{}) == :ok
    end

    test "verifies the captcha_token param on a guarded surface" do
      enable_captcha()
      stub_verify(true)

      assert Captcha.check(:register, %{"captcha_token" => "tok"}) == :ok
      assert Captcha.check(:register, %{}) == {:error, :captcha}
    end
  end
end
