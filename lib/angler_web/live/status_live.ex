defmodule AnglerWeb.StatusLive do
  @moduledoc """
  Single-status permalink at `/p/:username/:id`. This is the canonical web
  deep link a post's timestamp points to. Anonymous-visible statuses only
  (public / unlisted); anything else renders as not found.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Statuses
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @impl true
  def mount(%{"username" => username, "id" => id}, _session, socket) do
    with {int_id, ""} <- Integer.parse(id),
         %Status{} = status <- Statuses.get(int_id),
         true <- status.profile && status.profile.username == username,
         true <- Statuses.visible_to?(status, nil) do
      rendered = StatusJSON.render(status, nil)

      {:ok,
       socket
       |> assign(:page_title, "Post by @#{username}")
       |> assign(:status, rendered)}
    else
      _ ->
        {:ok,
         socket
         |> assign(:page_title, "Not found")
         |> assign(:status, nil)}
    end
  end

  @impl true
  def render(%{status: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <div class="text-center py-16 space-y-2">
        <h1 class="text-2xl font-bold">Post not found</h1>
        <p class="text-base-content/60">This post may be private, deleted, or never existed.</p>
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm mt-2">Back home</.link>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <.post_card status={@status} />
      <div class="mt-2 text-xs text-base-content/50">
        Permalink: <a href={@status["url"]} class="link link-hover">{@status["url"]}</a>
      </div>
    </Layouts.app>
    """
  end
end
