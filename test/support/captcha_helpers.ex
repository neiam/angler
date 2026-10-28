defmodule Angler.CaptchaHelpers do
  @moduledoc """
  Test helpers for `Angler.Captcha`: switch it on for the current test and
  stub the provider's siteverify endpoint through `Req.Test`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Enable the captcha with `opts` merged over a configured hCaptcha setup."
  def enable_captcha(opts \\ []) do
    previous = Application.get_env(:angler, :captcha)

    Application.put_env(
      :angler,
      :captcha,
      Keyword.merge(
        [enabled: true, driver: :hcaptcha, sitekey: "site-key", secret: "s3cret"],
        opts
      )
    )

    on_exit(fn -> restore(:captcha, previous) end)
    :ok
  end

  @doc """
  Route outbound Req calls to a stub answering siteverify with `success`.
  Each request is sent to the calling test as `{:captcha_verify, conn, body}`.
  """
  def stub_verify(success) do
    test = self()

    Req.Test.stub(:angler_http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:captcha_verify, conn, body})
      Req.Test.json(conn, %{"success" => success})
    end)

    previous = Application.get_env(:angler, :req_options)
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    Req.Test.set_req_test_to_shared(test)
    on_exit(fn -> restore(:req_options, previous) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:angler, key)
  defp restore(key, value), do: Application.put_env(:angler, key, value)
end
