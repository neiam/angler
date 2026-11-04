defmodule AnglerWeb.AdminSettingsLive do
  @moduledoc """
  Admin-only settings: edit the instance metadata shown on the about page
  (title, descriptions, contact, rules), registration (curated mode and
  captcha, as upstream's admin settings), and the admin team. Backed by
  `Angler.Instance` (DB overrides env) and `Angler.Accounts.set_admin/2`.

  Gated by `AnglerWeb.LiveAuth` `:require_admin`.
  """
  use AnglerWeb, :live_view

  alias Angler.Accounts
  alias Angler.Captcha
  alias Angler.Instance

  @surfaces [
    {"login", "Login"},
    {"register", "Registration"},
    {"curated_register", "Curated applications"},
    {"forgot_password", "Password reset requests"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin settings")
     |> assign_settings_form()
     |> assign(:surfaces, @surfaces)
     |> assign_registration_form()
     |> assign_toggles()
     |> assign_admins()}
  end

  defp assign_settings_form(socket) do
    s = Instance.get_settings()

    data = %{
      "title" => s.title || "",
      "short_description" => s.short_description || "",
      "description" => s.description || "",
      "contact_email" => s.contact_email || "",
      "contact_username" => s.contact_username || "",
      "rules" => Enum.join(s.rules || [], "\n")
    }

    assign(socket, :settings_form, to_form(data, as: :settings))
  end

  # Effective values (admin override, else env), so the form shows what's live.
  defp assign_registration_form(socket) do
    active = Captcha.setting(:active) || []

    data =
      %{
        "curated_enabled" => Instance.curated_registration_enabled?(),
        "curated_only_on_closed" => Instance.curated_config(:only_enabled_on_closed_reg, true),
        "captcha_enabled" => Captcha.enabled?(),
        "captcha_driver" => Atom.to_string(Captcha.driver()),
        "captcha_sitekey" => Captcha.setting(:sitekey) || "",
        "captcha_secret" => "",
        "cap_endpoint" => Captcha.setting(:cap_endpoint) || ""
      }
      |> Map.merge(
        Map.new(@surfaces, fn {s, _} ->
          {"active_" <> s, Keyword.get(active, String.to_existing_atom(s), true)}
        end)
      )

    socket
    |> assign(:registration_form, to_form(data, as: :registration))
    |> assign(:captcha_secret_set?, present?(Captcha.setting(:secret)))
    |> assign(:registration_overridden?, overridden?())
  end

  defp overridden? do
    s = Instance.get_settings()
    s.captcha not in [nil, %{}] or s.curated_registration not in [nil, %{}]
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  # The admin config switches, shared with the admin app's /api/admin/config.
  # Only the ones Angler acts on; the API still lists upstream's full set.
  @live_toggles ~w(open_registration stories_enabled)

  defp assign_toggles(socket),
    do: assign(socket, :toggles, live_toggles(Angler.Admin.Pixelfed.config_list()))

  defp live_toggles(list), do: Enum.filter(list, &(&1["key"] in @live_toggles))

  defp assign_admins(socket), do: assign(socket, :admins, Accounts.list_admins())

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    attrs = Map.put(params, "rules", split_lines(params["rules"]))

    case Instance.update_settings(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Instance settings saved.")
         |> assign_settings_form()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't save: #{changeset_error(changeset)}")}
    end
  end

  def handle_event("save_registration", %{"registration" => p}, socket) do
    on? = &(p[&1] == "true")

    curated = %{
      "enabled" => on?.("curated_enabled"),
      "only_enabled_on_closed_reg" => on?.("curated_only_on_closed")
    }

    # A blank secret keeps the current one (it's never echoed back).
    existing_secret =
      case Instance.override(:captcha, :secret) do
        {:ok, s} -> s
        :error -> nil
      end

    captcha =
      %{
        "enabled" => on?.("captcha_enabled"),
        "driver" => p["captcha_driver"],
        "sitekey" => blank_to_nil(p["captcha_sitekey"]),
        "secret" => blank_to_nil(p["captcha_secret"]) || existing_secret,
        "cap_endpoint" => blank_to_nil(p["cap_endpoint"]),
        "active" => Map.new(@surfaces, fn {s, _} -> {s, on?.("active_" <> s)} end)
      }
      |> Map.reject(fn {_, v} -> is_nil(v) end)

    with true <- p["captcha_driver"] in Enum.map(Captcha.drivers(), &Atom.to_string/1),
         {:ok, _} <- Instance.update_registration_settings(:curated_registration, curated),
         {:ok, _} <- Instance.update_registration_settings(:captcha, captcha) do
      {:noreply,
       socket |> put_flash(:info, "Registration settings saved.") |> assign_registration_form()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't save registration settings.")}
    end
  end

  def handle_event("toggle", %{"key" => key}, socket) do
    current = Enum.find(socket.assigns.toggles, &(&1["key"] == key))

    case current &&
           Angler.Admin.Pixelfed.update_config(
             socket.assigns.current_user,
             key,
             !current["state"]
           ) do
      {:ok, list} -> {:noreply, assign(socket, :toggles, live_toggles(list))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reset_registration", _params, socket) do
    {:ok, _} = Instance.update_registration_settings(:curated_registration, nil)
    {:ok, _} = Instance.update_registration_settings(:captcha, nil)

    {:noreply,
     socket
     |> put_flash(:info, "Registration settings now follow the environment.")
     |> assign_registration_form()}
  end

  def handle_event("promote", %{"username" => username}, socket) do
    case Accounts.lookup_by_handle(String.trim(username)) do
      %{} = user ->
        {:ok, _} = Accounts.set_admin(user, true)

        {:noreply,
         socket |> put_flash(:info, "Granted admin to @#{username}.") |> assign_admins()}

      _ ->
        {:noreply, put_flash(socket, :error, "No active local user @#{username}.")}
    end
  end

  def handle_event("demote", %{"username" => username}, socket) do
    if username == socket.assigns.current_profile.username do
      {:noreply, put_flash(socket, :error, "You can't remove your own admin access.")}
    else
      case Accounts.lookup_by_handle(username) do
        %{} = user ->
          {:ok, _} = Accounts.set_admin(user, false)

          {:noreply,
           socket |> put_flash(:info, "Removed admin from @#{username}.") |> assign_admins()}

        _ ->
          {:noreply, assign_admins(socket)}
      end
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp split_lines(nil), do: []

  defp split_lines(s) when is_binary(s),
    do: s |> String.split(["\r\n", "\n"]) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp changeset_error(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {f, msgs} -> "#{f} #{Enum.join(msgs, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-2xl space-y-8">
        <h1 class="text-2xl font-bold">Admin settings</h1>

        <section class="space-y-4">
          <h2 class="text-lg font-semibold">Instance</h2>
          <p class="text-sm text-base-content/60">
            Shown on the public about page. Leave a field blank to fall back to the
            environment configuration.
          </p>

          <.form for={@settings_form} phx-submit="save_settings" class="space-y-4">
            <.input field={@settings_form[:title]} label="Title" maxlength="120" />
            <.input
              field={@settings_form[:short_description]}
              label="Short description"
              maxlength="280"
            />
            <.input field={@settings_form[:description]} type="textarea" label="About / description" />
            <.input field={@settings_form[:contact_email]} type="email" label="Contact email" />
            <.input
              field={@settings_form[:contact_username]}
              label="Contact account (username)"
              placeholder="e.g. admin"
            />
            <.input
              field={@settings_form[:rules]}
              type="textarea"
              label="Server rules (one per line)"
            />
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
              Save instance settings
            </button>
          </.form>
        </section>

        <section id="feature-toggles" class="space-y-3">
          <h2 class="text-lg font-semibold">Features</h2>
          <ul class="divide-y divide-base-300 rounded-box border border-base-300">
            <li
              :for={t <- @toggles}
              id={"toggle-#{t["key"]}"}
              class="flex items-center justify-between gap-4 px-3 py-2"
            >
              <span class="min-w-0">
                <span class="block text-sm font-medium">{t["name"]}</span>
                <span class="block text-xs text-base-content/60">{t["description"]}</span>
              </span>
              <input
                type="checkbox"
                class="toggle toggle-primary"
                checked={t["state"]}
                phx-click="toggle"
                phx-value-key={t["key"]}
                aria-label={t["name"]}
              />
            </li>
          </ul>
        </section>

        <section id="registration-settings" class="space-y-4">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-lg font-semibold">Registration</h2>
            <.link navigate={~p"/admin/pages"} class="link text-sm">Site pages</.link>
            <button
              :if={@registration_overridden?}
              id="reset-registration"
              type="button"
              phx-click="reset_registration"
              data-confirm="Drop these overrides and use the environment configuration?"
              class="btn btn-ghost btn-xs"
            >
              Use environment settings
            </button>
          </div>
          <p class="text-sm text-base-content/60">
            Saving here overrides the environment variables (INSTANCE_CUR_REG, CAPTCHA_*)
            for every server until you switch back.
          </p>

          <.form
            for={@registration_form}
            id="registration-form"
            phx-submit="save_registration"
            class="space-y-6"
          >
            <fieldset class="space-y-2">
              <legend class="text-sm font-semibold">Curated registration</legend>
              <.input
                field={@registration_form[:curated_enabled]}
                type="checkbox"
                label="People apply for an account and an admin approves them"
              />
              <.input
                field={@registration_form[:curated_only_on_closed]}
                type="checkbox"
                label="Only while open registration is off"
              />
              <.link navigate={~p"/admin/curated-onboarding/templates"} class="link text-sm">
                Reply templates
              </.link>
            </fieldset>

            <fieldset class="space-y-3">
              <legend class="text-sm font-semibold">Captcha</legend>
              <.input field={@registration_form[:captcha_enabled]} type="checkbox" label="Enabled" />
              <.input
                field={@registration_form[:captcha_driver]}
                type="select"
                label="Provider"
                options={[
                  {"hCaptcha", "hcaptcha"},
                  {"Cloudflare Turnstile", "turnstile"},
                  {"Cap", "cap"}
                ]}
              />
              <.input field={@registration_form[:captcha_sitekey]} label="Site key" />
              <.input
                field={@registration_form[:captcha_secret]}
                type="password"
                label="Secret key"
                placeholder={if(@captcha_secret_set?, do: "Saved — leave blank to keep", else: "")}
                autocomplete="off"
              />
              <.input
                field={@registration_form[:cap_endpoint]}
                label="Cap endpoint (Cap only)"
                placeholder="https://cap.example.com"
              />
              <div class="space-y-1">
                <div class="text-sm font-medium">Ask on</div>
                <.input
                  :for={{key, label} <- @surfaces}
                  field={@registration_form["active_" <> key]}
                  type="checkbox"
                  label={label}
                />
              </div>
            </fieldset>

            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">
              Save registration settings
            </button>
          </.form>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-semibold">Administrators</h2>

          <form phx-submit="promote" class="flex gap-2 items-end">
            <div class="flex-1">
              <label class="label"><span class="label-text">Grant admin to username</span></label>
              <input name="username" placeholder="username" class="input w-full" required />
            </div>
            <button type="submit" class="btn btn-secondary">Promote</button>
          </form>

          <ul class="divide-y divide-base-300 rounded-box border border-base-300">
            <li
              :for={admin <- @admins}
              class="flex items-center justify-between gap-3 px-3 py-2"
            >
              <.link navigate={~p"/@#{admin.username}"} class="min-w-0">
                <span class="font-medium">{admin.name || admin.username}</span>
                <span class="text-xs text-base-content/60">@{admin.username}</span>
              </.link>
              <button
                :if={admin.username != @current_profile.username}
                phx-click="demote"
                phx-value-username={admin.username}
                data-confirm={"Remove admin from @#{admin.username}?"}
                class="btn btn-ghost btn-xs text-error"
              >
                Remove
              </button>
              <span
                :if={admin.username == @current_profile.username}
                class="text-xs text-base-content/50"
              >
                you
              </span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
