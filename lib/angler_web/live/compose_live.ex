defmodule AnglerWeb.ComposeLive do
  @moduledoc """
  Web post composer. Uploads are edited client-side first: the `PhotoEditor` JS
  hook draws the chosen image to a `<canvas>`, applies brightness/contrast/
  saturation + preset filters, then exports the touched-up result and pushes it
  into the LiveView upload via `this.upload/2`. So only the edited bytes ever
  reach the server.

  On submit we run the same pipeline the mobile API does — `Media.upload/3` per
  attachment, then `Statuses.create_local/2`, then `FeedInsert` + `StatusDeliver`
  so the post fans out and federates.
  """
  use AnglerWeb, :live_view

  alias Angler.Media.License
  alias Angler.Statuses
  alias Angler.Statuses.Workers.StatusDeliver
  alias Angler.Timelines.Workers.FeedInsert

  @visibilities [
    {"Public", "public"},
    {"Unlisted", "unlisted"},
    {"Followers only", "private"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/compose")}

      _profile ->
        {:ok,
         socket
         |> assign(:page_title, "New post")
         |> assign(:visibilities, @visibilities)
         |> assign(:licenses, License.all())
         |> assign(
           :default_license,
           Angler.Accounts.Settings.default_license(socket.assigns.current_user.id)
         )
         |> assign(
           :form,
           to_form(%{"caption" => "", "visibility" => "public", "sensitive" => false})
         )
         |> assign(:posting, false)
         |> allow_upload(:media,
           accept: ~w(.jpg .jpeg .png .webp .gif),
           max_entries: 4,
           max_file_size: 25_000_000,
           auto_upload: true
         )}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
  end

  def handle_event("post", %{"caption" => caption} = params, socket) do
    profile = socket.assigns.current_profile
    license = params["license"]

    media_ids =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Angler.Media.upload(profile, upload, %{"license" => license}) do
          {:ok, asset} -> {:ok, asset.id}
          {:error, reason} -> {:postpone, {:error, reason}}
        end
      end)

    cond do
      {:error, :account_size_limit} in media_ids ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You've used all your storage. Delete some posts to upload more."
         )}

      Enum.any?(media_ids, &match?({:error, _}, &1)) ->
        {:noreply, put_flash(socket, :error, "One of your photos couldn't be processed.")}

      media_ids == [] and String.trim(caption) == "" ->
        {:noreply, put_flash(socket, :error, "Add a photo or write something.")}

      true ->
        create_post(socket, profile, caption, media_ids, params)
    end
  end

  defp create_post(socket, profile, caption, media_ids, params) do
    attrs = %{
      "status" => caption,
      "media_ids" => media_ids,
      "visibility" => params["visibility"] || "public",
      "sensitive" => params["sensitive"] == "true"
    }

    case Statuses.create_local(profile, attrs) do
      {:ok, status} ->
        FeedInsert.enqueue(status.id)
        StatusDeliver.enqueue_for(status)

        {:noreply,
         socket
         |> put_flash(:info, "Posted!")
         |> push_navigate(to: ~p"/p/#{profile.username}/#{status.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't post (#{inspect(reason)}).")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-6">
        <h1 class="text-2xl font-bold">New post</h1>

        <form phx-submit="post" phx-change="validate" class="space-y-4">
          <%!-- Client-side photo editor. The hook owns the file picker, canvas
                preview and sliders, and pushes the edited image into :media. --%>
          <div
            id="photo-editor"
            phx-hook="PhotoEditor"
            phx-update="ignore"
            data-upload-name="media"
            class="space-y-3"
          >
            <input
              type="file"
              accept="image/*"
              data-role="file"
              class="file-input file-input-sm w-full"
            />

            <div data-role="stage" class="hidden space-y-3">
              <canvas data-role="canvas" class="w-full rounded-box border border-base-300 bg-base-300">
              </canvas>

              <div class="grid grid-cols-3 gap-2 text-xs">
                <label class="space-y-1">
                  <span>Brightness</span>
                  <input
                    type="range"
                    data-role="brightness"
                    min="50"
                    max="150"
                    value="100"
                    class="range range-xs"
                  />
                </label>
                <label class="space-y-1">
                  <span>Contrast</span>
                  <input
                    type="range"
                    data-role="contrast"
                    min="50"
                    max="150"
                    value="100"
                    class="range range-xs"
                  />
                </label>
                <label class="space-y-1">
                  <span>Saturation</span>
                  <input
                    type="range"
                    data-role="saturation"
                    min="0"
                    max="200"
                    value="100"
                    class="range range-xs"
                  />
                </label>
              </div>

              <div class="flex flex-wrap gap-1">
                <button type="button" data-preset="none" class="btn btn-xs">Original</button>
                <button type="button" data-preset="mono" class="btn btn-xs">Mono</button>
                <button type="button" data-preset="warm" class="btn btn-xs">Warm</button>
                <button type="button" data-preset="cool" class="btn btn-xs">Cool</button>
                <button type="button" data-preset="vivid" class="btn btn-xs">Vivid</button>
                <button type="button" data-role="add" class="btn btn-primary btn-xs ml-auto">
                  Add to post
                </button>
              </div>
            </div>
          </div>

          <div :if={@uploads.media.entries != []} class="grid grid-cols-4 gap-2">
            <div :for={entry <- @uploads.media.entries} class="relative">
              <.live_img_preview entry={entry} class="rounded-box w-full aspect-square object-cover" />
              <button
                type="button"
                phx-click="cancel"
                phx-value-ref={entry.ref}
                class="btn btn-circle btn-xs absolute top-1 right-1"
                aria-label="Remove"
              >
                ✕
              </button>
            </div>
          </div>

          <textarea
            name="caption"
            rows="3"
            placeholder="Write a caption…"
            class="textarea textarea-bordered w-full"
          >{@form[:caption].value}</textarea>

          <div class="flex flex-wrap items-center gap-3">
            <select name="visibility" class="select select-bordered select-sm">
              <option :for={{label, value} <- @visibilities} value={value}>{label}</option>
            </select>

            <select name="license" class="select select-bordered select-sm">
              <option
                :for={license <- @licenses}
                value={license.id}
                selected={license.id == @default_license}
              >
                {license.title}
              </option>
            </select>

            <label class="label cursor-pointer gap-2 text-sm">
              <input type="checkbox" name="sensitive" value="true" class="checkbox checkbox-sm" />
              <span>Sensitive</span>
            </label>
          </div>

          <button
            type="submit"
            class="btn btn-primary w-full"
            disabled={@posting}
            phx-disable-with="Posting…"
          >
            Post
          </button>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
