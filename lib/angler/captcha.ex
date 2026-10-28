defmodule Angler.Captcha do
  @moduledoc """
  Captcha checks for the signup and login surfaces, mirroring upstream's
  `App\\Services\\Captcha\\CaptchaManager` and its hCaptcha, Cloudflare
  Turnstile and Cap drivers (`config/captcha.php`).

  Configured under `config :angler, :captcha` (see `config/runtime.exs`):

    * `:enabled` — global switch, off by default
    * `:driver` — `:hcaptcha`, `:turnstile` or `:cap`
    * `:sitekey` / `:secret` — the active driver's keys
    * `:cap_endpoint` — Cap's base URL (the site key is appended, as upstream)
    * `:active` — surfaces it guards: `:login`, `:register`,
      `:curated_register`, `:forgot_password`
    * `:fail_open` — accept the submission if the provider can't be reached

  A surface is active only when the global switch is on, the driver has its
  keys, and the surface's own toggle is on — exactly `activeOn()` upstream.

  Tokens are verified server-side with a `Req` POST to the provider's
  siteverify URL. In tests, `config :angler, :req_options` (e.g.
  `plug: {Req.Test, :angler_http}`) is merged in, like `Angler.Federation.HTTP`.
  """

  require Logger

  @drivers [:hcaptcha, :turnstile, :cap]
  @surfaces [:login, :register, :curated_register, :forgot_password]

  @hcaptcha_verify "https://api.hcaptcha.com/siteverify"
  @hcaptcha_script "https://js.hcaptcha.com/1/api.js?render=explicit"
  @turnstile_verify "https://challenges.cloudflare.com/turnstile/v0/siteverify"
  @turnstile_script "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
  @cap_script "https://cdn.jsdelivr.net/npm/@cap.js/widget@"

  @doc "Name of the form field the widget writes its token into."
  @spec response_field() :: String.t()
  def response_field, do: "captcha_token"

  @doc "Supported driver names."
  @spec drivers() :: [atom()]
  def drivers, do: @drivers

  @doc "Whether captcha is globally switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, false) == true

  @doc "The active driver (defaults to hCaptcha, as upstream)."
  @spec driver() :: :hcaptcha | :turnstile | :cap
  def driver do
    case config(:driver, :hcaptcha) do
      d when d in @drivers -> d
      d when is_binary(d) -> Enum.find(@drivers, :hcaptcha, &(Atom.to_string(&1) == d))
      _ -> :hcaptcha
    end
  end

  @doc "Whether the active driver has everything it needs to verify."
  @spec configured?() :: boolean()
  def configured? do
    present?(config(:sitekey)) and present?(config(:secret)) and
      (driver() != :cap or present?(config(:cap_endpoint)))
  end

  @doc "Whether a captcha must be solved on `surface`."
  @spec active_on?(atom()) :: boolean()
  def active_on?(surface) when surface in @surfaces do
    enabled?() and configured?() and Keyword.get(config(:active, []), surface, true) == true
  end

  @doc """
  What the browser widget needs: the script to load, the driver and site key,
  plus Cap's API endpoint. Returned as string-keyed data for `data-*` attrs.
  """
  @spec widget() :: %{driver: String.t(), sitekey: String.t(), script: String.t(), api: String.t()}
  def widget do
    %{
      driver: Atom.to_string(driver()),
      sitekey: config(:sitekey) || "",
      script: script_url(driver()),
      api: cap_api() || ""
    }
  end

  defp script_url(:hcaptcha) do
    case config(:lang) do
      lang when is_binary(lang) and lang != "" -> @hcaptcha_script <> "&hl=" <> URI.encode(lang)
      _ -> @hcaptcha_script
    end
  end

  defp script_url(:turnstile), do: @turnstile_script
  defp script_url(:cap), do: @cap_script <> (config(:cap_widget_version) || "latest")

  @doc """
  Check `params[response_field()]` for `surface`. Returns `:ok` when the
  surface isn't guarded, so callers can run it unconditionally.
  """
  @spec check(atom(), map(), String.t() | nil) :: :ok | {:error, :captcha}
  def check(surface, params, remote_ip \\ nil) do
    if active_on?(surface) do
      case verify(params[response_field()], remote_ip) do
        true -> :ok
        false -> {:error, :captcha}
      end
    else
      :ok
    end
  end

  @doc "Verify a widget token with the active provider."
  @spec verify(String.t() | nil, String.t() | nil) :: boolean()
  def verify(token, remote_ip \\ nil)

  def verify(token, remote_ip) when is_binary(token) and token != "" do
    case verify_url(driver()) do
      nil -> false
      url -> post_verify(driver(), url, token, remote_ip)
    end
  end

  def verify(_token, _remote_ip), do: false

  defp verify_url(:hcaptcha), do: @hcaptcha_verify
  defp verify_url(:turnstile), do: @turnstile_verify
  defp verify_url(:cap), do: if(api = cap_api(), do: api <> "siteverify")

  defp post_verify(driver, url, token, remote_ip) do
    body = %{"secret" => config(:secret), "response" => token}
    # Cap takes JSON; hCaptcha and Turnstile take a form post with the
    # optional client IP.
    body_opt =
      if driver == :cap,
        do: [json: body],
        else: [form: maybe_put_ip(body, remote_ip)]

    opts =
      [url: url, receive_timeout: config(:timeout, 5) * 1_000, retry: false]
      |> Keyword.merge(body_opt)
      |> Keyword.merge(Application.get_env(:angler, :req_options, []))

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, body: %{"success" => success}}} ->
        success == true

      {:ok, %Req.Response{status: 200}} ->
        false

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("[captcha:#{driver}] verify returned HTTP #{status}")
        fail_open?()

      {:error, reason} ->
        Logger.warning("[captcha:#{driver}] verify request failed: #{inspect(reason)}")
        fail_open?()
    end
  end

  defp maybe_put_ip(body, ip) when is_binary(ip) and ip != "", do: Map.put(body, "remoteip", ip)
  defp maybe_put_ip(body, _), do: body

  defp fail_open?, do: config(:fail_open, false) == true

  # "{base}/{sitekey}/" — the full Cap API endpoint, as upstream's CapDriver.
  defp cap_api do
    base = (config(:cap_endpoint) || "") |> String.trim() |> String.trim_trailing("/")
    key = (config(:sitekey) || "") |> String.trim() |> String.trim("/")
    if base != "" and key != "", do: base <> "/" <> key <> "/"
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  defp config(key, default \\ nil) do
    Keyword.get(Application.get_env(:angler, :captcha, []), key, default)
  end
end
