defmodule AnglerWeb.InstagramImportLive do
  @moduledoc """
  Authenticated settings page to import an Instagram data export (JSON format).

  The user uploads their export `.zip`; we stage it on disk and enqueue
  `Angler.Import.Workers.InstagramImport`, which runs the backdated, silent
  import in the background (see `Angler.Import.Instagram`). The page subscribes
  to the worker's PubSub topic so it can report completion live.

  Large exports are better handled by the `mix angler.import_instagram` task —
  uploading multi-gigabyte archives over the LiveView socket is slow.
  """
  use AnglerWeb, :live_view

  alias Angler.Import.Workers.InstagramImport

  # 2 GB cap — generous for most exports; huge ones should use the mix task.
  @max_size 2_000_000_000

  @visibilities [
    {"Public", "public"},
    {"Unlisted", "unlisted"},
    {"Followers only", "private"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/import/instagram")}

      profile ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Angler.PubSub, InstagramImport.topic(profile.id))
        end

        {:ok,
         socket
         |> assign(:page_title, "Import from Instagram")
         |> assign(:visibilities, @visibilities)
         |> assign(:visibility, "public")
         |> assign(:result, nil)
         |> assign(:importing, InstagramImport.pending?(profile.id))
         |> allow_upload(:archive,
           accept: ~w(.zip),
           max_entries: 1,
           max_file_size: @max_size
         )}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :visibility, params["visibility"] || socket.assigns.visibility)}
  end

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :archive, ref)}
  end

  def handle_event("import", %{"visibility" => visibility}, socket) do
    profile = socket.assigns.current_profile

    staged =
      consume_uploaded_entries(socket, :archive, fn %{path: path}, _entry ->
        dest = Path.join(staging_dir(), "ig-#{System.unique_integer([:positive])}.zip")
        File.cp!(path, dest)
        {:ok, dest}
      end)

    case staged do
      [zip_path | _] ->
        case InstagramImport.enqueue(profile.id, zip_path, visibility: visibility) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> assign(:importing, true)
             |> assign(:result, nil)
             |> put_flash(:info, "Import queued — your posts will appear as it runs.")}

          {:error, reason} ->
            File.rm_rf(zip_path)
            {:noreply, put_flash(socket, :error, "Couldn't queue import (#{inspect(reason)}).")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Choose your Instagram export .zip first.")}
    end
  end

  @impl true
  def handle_info({:instagram_import_done, summary}, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:result, summary)
     |> put_flash(
       :info,
       "Import finished: #{summary.imported} imported, #{summary.skipped} skipped, #{summary.failed} failed."
     )}
  end

  def handle_info({:instagram_import_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> put_flash(:error, "Import failed: #{inspect(reason)}")}
  end

  defp staging_dir do
    dir = Path.join(System.tmp_dir!(), "angler-instagram-imports")
    File.mkdir_p!(dir)
    dir
  end

  # Friendlier copy for the upload errors LiveView can raise.
  defp upload_error(:too_large), do: "That file is larger than the 2 GB limit."
  defp upload_error(:not_accepted), do: "Only a .zip export is accepted."
  defp upload_error(:too_many_files), do: "Upload a single .zip file."
  defp upload_error(other), do: "Upload error: #{inspect(other)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-6">
        <h1 class="text-2xl font-bold">Import from Instagram</h1>

        <div class="alert alert-info text-sm">
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          <div class="space-y-1">
            <p>
              Request your data from Instagram in <span class="font-semibold">JSON</span>
              format ("Download Your Information"), then upload the <code>.zip</code>
              here.
            </p>
            <p class="text-xs opacity-80">
              Posts keep their original dates and are added quietly to your profile —
              your followers won't be flooded with old posts. Re-uploading is safe.
            </p>
          </div>
        </div>

        <form phx-change="validate" phx-submit="import" class="space-y-5">
          <div class="space-y-2">
            <div class="text-sm font-medium">Instagram export (.zip)</div>
            <.live_file_input upload={@uploads.archive} class="file-input file-input-sm w-full" />

            <div :for={entry <- @uploads.archive.entries} class="space-y-1">
              <div class="flex items-center justify-between text-xs">
                <span class="truncate">{entry.client_name}</span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="cancel"
                  phx-value-ref={entry.ref}
                  aria-label="Remove file"
                >
                  Remove
                </button>
              </div>
              <progress class="progress progress-primary w-full" value={entry.progress} max="100">
                {entry.progress}%
              </progress>
              <p :for={err <- upload_errors(@uploads.archive, entry)} class="text-xs text-error">
                {upload_error(err)}
              </p>
            </div>

            <p :for={err <- upload_errors(@uploads.archive)} class="text-xs text-error">
              {upload_error(err)}
            </p>
          </div>

          <.input
            type="select"
            name="visibility"
            label="Visibility for imported posts"
            value={@visibility}
            options={@visibilities}
          />

          <button
            type="submit"
            class="btn btn-primary w-full"
            disabled={@importing}
            phx-disable-with="Queuing…"
          >
            {if @importing, do: "Import in progress…", else: "Start import"}
          </button>
        </form>

        <div :if={@importing} class="alert text-sm">
          <span class="loading loading-spinner loading-sm"></span>
          <span>Importing in the background. You can leave this page; it keeps running.</span>
        </div>

        <div :if={@result} class="card bg-base-200 border border-base-300">
          <div class="card-body p-4 text-sm space-y-1">
            <h2 class="font-semibold">Last import</h2>
            <ul class="list-disc list-inside opacity-90">
              <li>{@result.posts} posts found</li>
              <li>{@result.imported} imported</li>
              <li>{@result.skipped} skipped (already present)</li>
              <li>{@result.failed} failed</li>
            </ul>
            <p :if={@result.errors != []} class="text-xs text-base-content/60">
              First issue: {List.first(@result.errors)}
            </p>
          </div>
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
end
