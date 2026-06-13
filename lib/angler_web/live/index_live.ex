defmodule AnglerWeb.IndexLive do
  @moduledoc """
  Public landing page: instance description + stats + contact, with a live
  feed of the latest local public posts.

  The feed seeds from `Timelines.public/2` (local only) and stays current by
  subscribing to the `"public:local"` streaming topic — the same bus the
  Mastodon WebSocket handler uses, so new posts appear without a refresh.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Instance
  alias Angler.Pagination.MastodonCursor
  alias Angler.Timelines
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @feed_limit 30
  @topic "public:local"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Angler.Streaming.subscribe(@topic)

    {posts, _} = Timelines.public(MastodonCursor.parse(%{}, @feed_limit, 40), local_only: true)
    rendered = StatusJSON.render_many(posts, nil)

    {:ok,
     socket
     |> assign(:page_title, Instance.title())
     |> assign(:stats, Instance.stats())
     |> assign(:instance, instance_meta())
     |> assign(:registration, registration_state())
     |> assign(:post_count, length(rendered))
     |> stream(:posts, rendered, dom_id: &dom_id/1)}
  end

  @impl true
  def handle_info({:streaming, @topic, "update", payload}, socket) do
    case Jason.decode(payload) do
      {:ok, status} ->
        {:noreply,
         socket
         |> stream_insert(:posts, status, at: 0, dom_id: &dom_id/1)
         |> update(:post_count, &(&1 + 1))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:streaming, @topic, "delete", payload}, socket) do
    case Jason.decode(payload) do
      {:ok, id} when is_binary(id) ->
        {:noreply,
         socket
         |> stream_delete_by_dom_id(:posts, "post-" <> id)
         |> update(:post_count, &max(&1 - 1, 0))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp dom_id(status), do: "post-" <> status["id"]

  defp instance_meta do
    %{
      title: Instance.title(),
      short_description: Instance.short_description(),
      description: Instance.description(),
      contact_email: Instance.contact_email(),
      rules: Instance.rules()
    }
  end

  defp registration_state do
    %{open?: Instance.open_registration?(), approval?: Instance.approval_required?()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_profile={@current_profile}>
      <section class="space-y-6">
        <div class="space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">{@instance.title}</h1>
          <p class="text-base-content/70">{@instance.short_description}</p>
          <p
            :if={@instance.description != @instance.short_description}
            class="text-sm text-base-content/70 whitespace-pre-line"
          >
            {@instance.description}
          </p>
        </div>

        <div class="grid grid-cols-3 gap-3">
          <.stat label="Users" value={@stats.user_count} />
          <.stat label="Posts" value={@stats.status_count} />
          <.stat label="Known servers" value={@stats.domain_count} />
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <%= cond do %>
            <% @current_user -> %>
              <span class="text-sm text-base-content/60">You're signed in.</span>
            <% @registration.open? -> %>
              <.link navigate={~p"/register"} class="btn btn-primary btn-sm">
                Create an account
              </.link>
              <span :if={@registration.approval?} class="text-xs text-base-content/60">
                New accounts require operator approval.
              </span>
            <% true -> %>
              <span class="text-sm text-base-content/60">Registration is currently closed.</span>
          <% end %>
          <.link :if={!@current_user} navigate={~p"/login"} class="btn btn-ghost btn-sm">
            Log in
          </.link>
        </div>

        <div :if={@instance.contact_email} class="text-sm text-base-content/60">
          Contact:
          <a href={"mailto:#{@instance.contact_email}"} class="link link-hover">
            {@instance.contact_email}
          </a>
        </div>

        <ul :if={@instance.rules != []} class="text-sm text-base-content/70 list-disc pl-5 space-y-1">
          <li :for={rule <- @instance.rules}>{rule}</li>
        </ul>
      </section>

      <section class="mt-8 space-y-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <span class="inline-block size-2 rounded-full bg-success motion-safe:animate-pulse" />
          Latest public posts
        </h2>

        <div id="feed" phx-update="stream" class="space-y-3">
          <.post_card :for={{dom_id, status} <- @streams.posts} id={dom_id} status={status} />
        </div>

        <p :if={@post_count == 0} class="text-sm text-base-content/60">No public posts yet.</p>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body items-center p-4">
        <div class="text-2xl font-bold tabular-nums">{@value}</div>
        <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      </div>
    </div>
    """
  end
end
