defmodule AnglerWeb.AntiSpamComponents do
  @moduledoc """
  Form widgets for the signup protections: the captcha widget (upstream's
  `<x-captcha>` Blade component) and the honeypot field (upstream's
  `@honeypot`).

  The provider's script can't be a `<script src>` in the layout, so the
  `.Captcha` colocated hook injects it once when the widget mounts, renders
  the provider widget explicitly, and writes the solved token into a hidden
  `captcha_token` input. Both live inside `phx-update="ignore"`, so LiveView
  re-renders never wipe the widget or the token. The server pushes
  `captcha:reset` after a failed submit, since tokens are single-use.
  """
  use Phoenix.Component

  import AnglerWeb.CoreComponents, only: [input: 1]

  attr :id, :string, required: true
  attr :widget, :map, required: true, doc: "from `Angler.Captcha.widget/0`"

  def captcha(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".Captcha"
      phx-update="ignore"
      data-driver={@widget.driver}
      data-sitekey={@widget.sitekey}
      data-script={@widget.script}
      data-api={@widget.api}
      class="flex justify-center min-h-16"
    >
      <.input
        type="hidden"
        id={@id <> "-token"}
        name={Angler.Captcha.response_field()}
        value=""
        data-captcha-token
      />
      <div data-captcha-box></div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Captcha">
      const loads = (window.__anglerCaptchaLoads ||= {})

      function loadScript(src) {
        if (!loads[src]) {
          loads[src] = new Promise((resolve, reject) => {
            const s = document.createElement("script")
            s.src = src
            s.async = true
            s.onload = () => resolve()
            s.onerror = () => { delete loads[src]; reject(new Error("captcha script failed")) }
            document.head.appendChild(s)
          })
        }
        return loads[src]
      }

      export default {
        mounted() {
          const {driver, sitekey, script, api} = this.el.dataset
          this.driver = driver
          this.token = this.el.querySelector("[data-captcha-token]")
          this.box = this.el.querySelector("[data-captcha-box]")
          this.handleEvent("captcha:reset", () => this.reset())

          const set = (value) => {
            this.token.value = value || ""
            this.token.dispatchEvent(new Event("input", {bubbles: true}))
          }

          loadScript(script).then(() => {
            if (!this.box.isConnected) return
            if (driver === "hcaptcha" && window.hcaptcha) {
              this.widgetId = window.hcaptcha.render(this.box, {
                sitekey, callback: set, "expired-callback": () => set("")
              })
            } else if (driver === "turnstile" && window.turnstile) {
              this.widgetId = window.turnstile.render(this.box, {
                sitekey, callback: set, "expired-callback": () => set("")
              })
            } else if (driver === "cap") {
              const w = document.createElement("cap-widget")
              w.setAttribute("data-cap-api-endpoint", api)
              w.addEventListener("solve", (e) => set(e.detail && e.detail.token))
              this.box.appendChild(w)
              this.capWidget = w
            }
          }).catch(() => {})
        },
        reset() {
          this.token.value = ""
          if (this.widgetId === undefined && !this.capWidget) return
          if (this.driver === "hcaptcha" && window.hcaptcha) window.hcaptcha.reset(this.widgetId)
          if (this.driver === "turnstile" && window.turnstile) window.turnstile.reset(this.widgetId)
          if (this.capWidget && typeof this.capWidget.reset === "function") this.capWidget.reset()
        },
        destroyed() {
          if (this.widgetId === undefined) return
          if (this.driver === "hcaptcha" && window.hcaptcha) window.hcaptcha.remove(this.widgetId)
          if (this.driver === "turnstile" && window.turnstile) window.turnstile.remove(this.widgetId)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :honeypot, AnglerWeb.Honeypot, required: true

  def honeypot(assigns) do
    ~H"""
    <div id={@id} class="hidden" aria-hidden="true">
      <.input
        type="text"
        id={@id <> "-field"}
        name={@honeypot.field}
        value=""
        label="Leave this field empty"
        tabindex="-1"
        autocomplete="off"
      />
    </div>
    """
  end
end
