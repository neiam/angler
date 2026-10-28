defmodule AnglerWeb.ProfileEditLive do
  @moduledoc """
  Authenticated profile editor for the web frontend. Reuses the same context
  the API does — `Profiles.update_credentials/2` for profile fields + avatar/
  header, and `Accounts.Settings.apply_account_params/2` for the privacy/display
  toggles — so web and app edits stay consistent.
  """
  use AnglerWeb, :live_view

  alias Angler.Accounts.Settings
  alias Angler.Profiles

  # {param key, label, help}
  @toggles [
    {"locked", "Private account", "Approve followers; posts hidden from the public timeline"},
    {"is_suggestable", "Suggest my account", "Appear in directory / suggested-profile lists"},
    {"indexable", "Indexable", "Allow search engines to index your profile"},
    {"crawlable", "Crawlable", "Allow crawlers to read your public profile"},
    {"public_dm", "Public DMs", "Let anyone start a direct message"},
    {"show_profile_follower_count", "Show follower count", nil},
    {"show_profile_following_count", "Show following count", nil},
    {"disable_embeds", "Disable embeds", nil},
    {"show_atom", "Expose Atom feed", nil},
    {"reduce_motion", "Reduce motion", nil},
    {"high_contrast_mode", "High contrast", nil},
    {"video_autoplay", "Autoplay video", nil},
    {"media_descriptions", "Require alt text", nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/profile")}

      profile ->
        {:ok,
         socket
         |> assign(:page_title, "Edit profile")
         |> assign(:toggles, @toggles)
         |> assign_form(profile)
         |> allow_upload(:avatar,
           accept: ~w(.jpg .jpeg .png .webp .gif),
           max_entries: 1,
           max_file_size: 15_000_000
         )
         |> allow_upload(:header,
           accept: ~w(.jpg .jpeg .png .webp .gif),
           max_entries: 1,
           max_file_size: 15_000_000
         )}
    end
  end

  defp assign_form(socket, profile) do
    settings = Settings.account_settings(socket.assigns.current_user.id)

    base = %{
      "display_name" => profile.name || "",
      "note" => profile.bio_text || "",
      "website" => profile.website || "",
      "location" => profile.location || "",
      "pronouns" => Enum.join(profile.pronouns || [], ", "),
      "locked" => profile.is_private,
      "is_suggestable" => profile.discoverable,
      "indexable" => profile.indexable_search,
      "default_license" => Settings.default_license(socket.assigns.current_user.id),
      "can_quote" => settings["can_quote"]
    }

    toggle_keys = for {k, _, _} <- @toggles, k not in Map.keys(base), do: k
    data = Enum.reduce(toggle_keys, base, fn k, acc -> Map.put(acc, k, settings[k]) end)

    assign(socket, form: to_form(data, as: :profile), current_profile: profile)
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"profile" => params}, socket) do
    %{current_user: user, current_profile: profile} = socket.assigns
    base = Map.put(params, "pronouns", split_pronouns(params["pronouns"]))

    with {:ok, attrs} <- put_upload(base, socket, :avatar, "avatar_path", profile),
         {:ok, attrs} <- put_upload(attrs, socket, :header, "header_path", profile),
         {:ok, updated} <- Profiles.update_credentials(profile, attrs),
         {:ok, _settings} <- Settings.apply_account_params(user.id, attrs),
         {:ok, _license} <- maybe_set_license(user.id, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Profile updated.")
       |> assign_form(updated)}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Couldn't save: #{changeset_error(cs)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save (#{inspect(reason)}).")}
    end
  end

  # Persist the chosen default media license. An out-of-range value is ignored
  # rather than failing the whole save (the select only offers valid ids).
  defp maybe_set_license(user_id, %{"default_license" => v}) when v not in [nil, ""] do
    case Settings.set_default_license(user_id, v) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:ok, :unchanged}
    end
  end

  defp maybe_set_license(_user_id, _attrs), do: {:ok, :unchanged}

  defp quote_options,
    do: [{"everyone", "Anyone"}, {"followers", "Your followers"}, {"nobody", "No one"}]

  defp split_pronouns(nil), do: []

  defp split_pronouns(s) when is_binary(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  # Upload INSIDE the consume callback: LiveView deletes the temp file as soon
  # as `consume_uploaded_entries` returns, so `Media.upload` (which reads the
  # bytes to sniff/hash) must run while the file still exists. We stash the
  # resulting media URL straight into `url_field` (avatar_path / header_path).
  defp put_upload(attrs, socket, upload_name, url_field, profile) do
    results =
      consume_uploaded_entries(socket, upload_name, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Angler.Media.upload(profile, upload) do
          {:ok, asset} ->
            url =
              Angler.Media.Storage.url(asset, :preview) ||
                Angler.Media.Storage.url(asset, :original)

            {:ok, {:ok, url}}

          {:error, reason} ->
            {:ok, {:error, reason}}
        end
      end)

    case results do
      [{:ok, url} | _] -> {:ok, Map.put(attrs, url_field, url)}
      [{:error, reason} | _] -> {:error, reason}
      [] -> {:ok, attrs}
    end
  end

  defp changeset_error(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {f, msgs} -> "#{f} #{Enum.join(msgs, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-6">
        <h1 class="text-2xl font-bold">Edit profile</h1>

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-5">
          <.input field={@form[:display_name]} label="Display name" maxlength="30" />
          <.input field={@form[:note]} type="textarea" label="Bio" maxlength="200" />
          <.input field={@form[:website]} label="Website" maxlength="120" />
          <.input field={@form[:location]} label="Location" maxlength="60" />
          <.input field={@form[:pronouns]} label="Pronouns" placeholder="she, her" />

          <div class="space-y-2">
            <div class="text-sm font-medium">Avatar</div>
            <.live_file_input upload={@uploads.avatar} class="file-input file-input-sm w-full" />
          </div>
          <div class="space-y-2">
            <div class="text-sm font-medium">Header</div>
            <.live_file_input upload={@uploads.header} class="file-input file-input-sm w-full" />
          </div>

          <div class="divider">Media</div>

          <label class="block space-y-1">
            <span class="text-sm font-medium">Default photo license</span>
            <span class="block text-xs text-base-content/60">
              Applied to new uploads unless overridden per post.
            </span>
            <select name="profile[default_license]" class="select select-bordered w-full">
              <option
                :for={license <- license_options()}
                value={license.id}
                selected={to_string(license.id) == to_string(@form[:default_license].value)}
              >
                {license.title}
              </option>
            </select>
          </label>

          <div class="divider">Privacy &amp; display</div>

          <label class="block space-y-1">
            <span class="text-sm font-medium">Who can quote your posts</span>
            <span class="block text-xs text-base-content/60">
              Applies to public and unlisted posts, unless you set it per post.
            </span>
            <select
              id="profile-can-quote"
              name="profile[can_quote]"
              class="select select-bordered w-full"
            >
              <option
                :for={{value, label} <- quote_options()}
                value={value}
                selected={value == @form[:can_quote].value}
              >
                {label}
              </option>
            </select>
          </label>

          <div class="space-y-2">
            <label :for={{key, label, help} <- @toggles} class="flex items-start gap-3 cursor-pointer">
              <input type="hidden" name={"profile[#{key}]"} value="false" />
              <input
                type="checkbox"
                name={"profile[#{key}]"}
                value="true"
                checked={truthy(@form[key].value)}
                class="checkbox checkbox-sm mt-0.5"
              />
              <span>
                <span class="text-sm font-medium">{label}</span>
                <span :if={help} class="block text-xs text-base-content/60">{help}</span>
              </span>
            </label>
          </div>

          <button type="submit" class="btn btn-primary w-full" phx-disable-with="Saving…">
            Save changes
          </button>
        </.form>

        <div class="divider">More settings</div>

        <div class="grid grid-cols-2 gap-2 text-sm">
          <.link navigate={~p"/settings/two-factor"} class="btn btn-ghost btn-sm justify-start">
            <.icon name="hero-finger-print" class="size-4" /> Two-factor auth
          </.link>
          <.link navigate={~p"/settings/filters"} class="btn btn-ghost btn-sm justify-start">
            <.icon name="hero-funnel" class="size-4" /> Filters
          </.link>
          <.link navigate={~p"/settings/followed-tags"} class="btn btn-ghost btn-sm justify-start">
            <.icon name="hero-hashtag" class="size-4" /> Followed tags
          </.link>
          <.link navigate={~p"/settings/quotes"} class="btn btn-ghost btn-sm justify-start">
            <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" /> Quotes
          </.link>
          <.link navigate={~p"/settings/data"} class="btn btn-ghost btn-sm justify-start">
            <.icon name="hero-arrow-down-tray" class="size-4" /> Import &amp; export
          </.link>
        </div>

        <p class="text-center text-sm">
          <.link navigate={~p"/@#{@current_profile.username}"} class="link link-hover">
            View my profile
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  defp license_options, do: Angler.Media.License.all()
end
