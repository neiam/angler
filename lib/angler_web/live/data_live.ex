defmodule AnglerWeb.DataLive do
  @moduledoc """
  Authenticated "Import & export" hub. Gathers the data-portability flows in one
  place:

    * Import — link out to the Instagram importer and an inline uploader for a
      Mastodon/Pixelfed account export (`Angler.Import.Workers.MastodonImport`).
    * Export — request a full account archive (`Angler.Export.Workers.AccountArchive`,
      downloaded via `AnglerWeb.ExportController`) or grab posts-as-JSON directly.

  Subscribes to the Mastodon-import and account-export PubSub topics so progress
  shows live.
  """
  use AnglerWeb, :live_view

  alias Angler.Export.Workers.AccountArchive
  alias Angler.Import.Workers.MastodonImport

  @max_size 2_000_000_000

  @visibilities [
    {"Keep original", ""},
    {"Public", "public"},
    {"Unlisted", "unlisted"},
    {"Followers only", "private"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_profile do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/login?next=/settings/data")}

      profile ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Angler.PubSub, MastodonImport.topic(profile.id))
          Phoenix.PubSub.subscribe(Angler.PubSub, AccountArchive.topic(profile.id))
        end

        {:ok,
         socket
         |> assign(:page_title, "Import & export")
         |> assign(:visibilities, @visibilities)
         |> assign(:visibility, "")
         |> assign(:mastodon_importing, MastodonImport.pending?(profile.id))
         |> assign(:exporting, AccountArchive.pending?(profile.id))
         |> assign(:export_ready, export_ready?(profile.id))
         |> assign(:import_result, nil)
         |> allow_upload(:archive, accept: ~w(.zip), max_entries: 1, max_file_size: @max_size)}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :visibility, params["visibility"] || socket.assigns.visibility)}
  end

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :archive, ref)}
  end

  def handle_event("import_mastodon", %{"visibility" => visibility}, socket) do
    profile = socket.assigns.current_profile

    staged =
      consume_uploaded_entries(socket, :archive, fn %{path: path}, _entry ->
        dest = Path.join(staging_dir(), "masto-#{System.unique_integer([:positive])}.zip")
        File.cp!(path, dest)
        {:ok, dest}
      end)

    opts =
      if visibility in ["public", "unlisted", "private"], do: [visibility: visibility], else: []

    case staged do
      [zip_path | _] ->
        case MastodonImport.enqueue(profile.id, zip_path, opts) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> assign(:mastodon_importing, true)
             |> assign(:import_result, nil)
             |> put_flash(:info, "Import queued — your posts will appear as it runs.")}

          {:error, reason} ->
            File.rm_rf(zip_path)
            {:noreply, put_flash(socket, :error, "Couldn't queue import (#{inspect(reason)}).")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Choose your export .zip first.")}
    end
  end

  def handle_event("request_export", _params, socket) do
    profile = socket.assigns.current_profile

    case AccountArchive.enqueue(profile.id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:exporting, true)
         |> put_flash(:info, "Building your archive — the download appears when it's ready.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't start export (#{inspect(reason)}).")}
    end
  end

  @impl true
  def handle_info({:mastodon_import_done, summary}, socket) do
    {:noreply,
     socket
     |> assign(:mastodon_importing, false)
     |> assign(:import_result, summary)
     |> put_flash(
       :info,
       "Import finished: #{summary.imported} imported, #{summary.skipped} skipped, #{summary.failed} failed."
     )}
  end

  def handle_info({:mastodon_import_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:mastodon_importing, false)
     |> put_flash(:error, "Import failed: #{inspect(reason)}")}
  end

  def handle_info({:account_export_done, summary}, socket) do
    {:noreply,
     socket
     |> assign(:exporting, false)
     |> assign(:export_ready, true)
     |> put_flash(:info, "Archive ready: #{summary.count} posts, #{summary.media} media files.")}
  end

  def handle_info({:account_export_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:exporting, false)
     |> put_flash(:error, "Export failed: #{inspect(reason)}")}
  end

  defp export_ready?(profile_id) do
    dir = Angler.Export.AccountArchive.default_dir(profile_id)
    File.dir?(dir) and Path.wildcard(Path.join(dir, "*.zip")) != []
  end

  defp staging_dir do
    dir = Path.join(System.tmp_dir!(), "angler-mastodon-imports")
    File.mkdir_p!(dir)
    dir
  end

  defp upload_error(:too_large), do: "That file is larger than the 2 GB limit."
  defp upload_error(:not_accepted), do: "Only a .zip export is accepted."
  defp upload_error(:too_many_files), do: "Upload a single .zip file."
  defp upload_error(other), do: "Upload error: #{inspect(other)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="mx-auto max-w-xl space-y-8">
        <div>
          <h1 class="text-2xl font-bold">Import &amp; export</h1>
          <p class="mt-1 text-sm text-base-content/70">
            Bring posts in from other platforms, or take your data with you.
          </p>
        </div>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Import</h2>

          <.link
            navigate={~p"/settings/import/instagram"}
            class="card bg-base-200 border border-base-300 block hover:border-primary"
          >
            <div class="card-body flex-row items-center gap-3 p-4">
              <.icon name="hero-photo" class="size-6 shrink-0" />
              <div class="min-w-0 flex-1">
                <div class="font-semibold">Instagram</div>
                <div class="text-xs text-base-content/60">Import your Instagram JSON export.</div>
              </div>
              <.icon name="hero-chevron-right" class="size-5 shrink-0 opacity-60" />
            </div>
          </.link>

          <form
            phx-change="validate"
            phx-submit="import_mastodon"
            class="card bg-base-200 border border-base-300"
          >
            <div class="card-body gap-3 p-4">
              <div class="flex items-center gap-3">
                <.icon name="hero-arrow-down-tray" class="size-6 shrink-0" />
                <div>
                  <div class="font-semibold">Mastodon or Pixelfed</div>
                  <div class="text-xs text-base-content/60">
                    Upload an account export <code>.zip</code> (with <code>outbox.json</code>).
                  </div>
                </div>
              </div>

              <.live_file_input upload={@uploads.archive} class="file-input file-input-sm w-full" />

              <div :for={entry <- @uploads.archive.entries} class="space-y-1">
                <div class="flex items-center justify-between text-xs">
                  <span class="truncate">{entry.client_name}</span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="cancel"
                    phx-value-ref={entry.ref}
                  >
                    Remove
                  </button>
                </div>
                <progress class="progress progress-primary w-full" value={entry.progress} max="100" />
                <p :for={err <- upload_errors(@uploads.archive, entry)} class="text-xs text-error">
                  {upload_error(err)}
                </p>
              </div>

              <div class="flex items-center gap-2">
                <select name="visibility" class="select select-bordered select-sm">
                  <option
                    :for={{label, value} <- @visibilities}
                    value={value}
                    selected={value == @visibility}
                  >
                    {label}
                  </option>
                </select>
                <button
                  type="submit"
                  class="btn btn-primary btn-sm ml-auto"
                  disabled={@mastodon_importing}
                  phx-disable-with="Queuing…"
                >
                  {if @mastodon_importing, do: "Importing…", else: "Import"}
                </button>
              </div>

              <div :if={@import_result} class="text-xs text-base-content/70">
                Last import: {@import_result.imported} imported, {@import_result.skipped} skipped, {@import_result.failed} failed.
              </div>
            </div>
          </form>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Export</h2>

          <div class="card bg-base-200 border border-base-300">
            <div class="card-body gap-3 p-4">
              <div class="flex items-center gap-3">
                <.icon name="hero-archive-box" class="size-6 shrink-0" />
                <div class="min-w-0 flex-1">
                  <div class="font-semibold">Account archive</div>
                  <div class="text-xs text-base-content/60">
                    A <code>.zip</code> with your actor, outbox (ActivityPub), and media.
                  </div>
                </div>
              </div>

              <div class="flex items-center gap-2">
                <button
                  type="button"
                  class="btn btn-primary btn-sm"
                  phx-click="request_export"
                  disabled={@exporting}
                  phx-disable-with="Building…"
                >
                  {if @exporting, do: "Building…", else: "Build archive"}
                </button>

                <.link
                  :if={@export_ready}
                  href={~p"/settings/data/export"}
                  class="btn btn-outline btn-sm"
                >
                  <.icon name="hero-arrow-down-tray" class="size-4" /> Download
                </.link>
              </div>

              <div :if={@exporting} class="text-xs text-base-content/60">
                Building in the background — you can leave this page.
              </div>
            </div>
          </div>

          <.link
            href={~p"/settings/data/posts.json"}
            class="card bg-base-200 border border-base-300 block hover:border-primary"
          >
            <div class="card-body flex-row items-center gap-3 p-4">
              <.icon name="hero-code-bracket" class="size-6 shrink-0" />
              <div class="min-w-0 flex-1">
                <div class="font-semibold">Posts as JSON</div>
                <div class="text-xs text-base-content/60">
                  Your posts as ActivityPub objects (no media).
                </div>
              </div>
              <.icon name="hero-arrow-down-tray" class="size-5 shrink-0 opacity-60" />
            </div>
          </.link>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
