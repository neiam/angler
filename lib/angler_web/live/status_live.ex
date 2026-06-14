defmodule AnglerWeb.StatusLive do
  @moduledoc """
  Single-status permalink at `/p/:username/:id`. This is the canonical web
  deep link a post's timestamp points to. Anonymous-visible statuses only
  (public / unlisted); anything else renders as not found.
  """
  use AnglerWeb, :live_view

  import AnglerWeb.PublicComponents

  alias Angler.Profiles.Profile
  alias Angler.Statuses
  alias Angler.Statuses.Status
  alias Angler.Statuses.Workers.StatusDeliver
  alias Angler.Timelines.Workers.FeedInsert
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @impl true
  def mount(%{"username" => username, "id" => id}, _session, socket) do
    viewer_id = socket.assigns.current_profile && socket.assigns.current_profile.id

    with {int_id, ""} <- Integer.parse(id),
         %Status{} = status <- Statuses.get(int_id),
         true <- status.profile && status.profile.username == username,
         true <- Statuses.visible_to?(status, viewer_id) do
      rendered = StatusJSON.render(status, viewer_id)
      comments = status |> Statuses.descendants(viewer_id) |> StatusJSON.render_many(viewer_id)

      {:ok,
       socket
       |> assign(:page_title, "Post by @#{username}")
       |> assign(:status, rendered)
       |> assign(:comments, comments)
       |> assign(:reply_form, reply_form())
       |> assign(:open_reply, nil)}
    else
      _ ->
        {:ok,
         socket
         |> assign(:page_title, "Not found")
         |> assign(:status, nil)
         |> assign(:comments, [])
         |> assign(:reply_form, reply_form())
         |> assign(:open_reply, nil)}
    end
  end

  defp reply_form, do: to_form(%{"body" => ""}, as: :reply)

  @impl true
  def handle_event("favourite", %{"id" => id}, socket), do: react(socket, id, :favourite)
  def handle_event("reblog", %{"id" => id}, socket), do: react(socket, id, :reblog)

  def handle_event("toggle_reply", %{"id" => id}, socket) do
    open = if socket.assigns.open_reply == id, do: nil, else: id
    {:noreply, assign(socket, :open_reply, open)}
  end

  def handle_event("reply", %{"reply" => %{"body" => body, "parent_id" => parent_id}}, socket) do
    with %Profile{} = profile <- socket.assigns.current_profile,
         %{} <- socket.assigns.status,
         body when is_binary(body) <- body,
         true <- String.trim(body) != "",
         {:ok, reply} <-
           Statuses.create_local(profile, %{
             "status" => body,
             "in_reply_to_id" => parent_id
           }) do
      # Mirror the API create path so the reply fans out + federates.
      FeedInsert.enqueue(reply.id)
      StatusDeliver.enqueue_for(reply)

      rendered = StatusJSON.render(reply, profile.id)

      {:noreply,
       socket
       |> update(:comments, &(&1 ++ [rendered]))
       |> bump_root_count(parent_id)
       |> assign(:open_reply, nil)
       |> assign(:reply_form, reply_form())}
    else
      false -> {:noreply, socket}
      _ -> {:noreply, put_flash(socket, :error, "Couldn't post that reply.")}
    end
  end

  # Only the post's *direct* reply count lives on the main card; nested replies
  # don't change it.
  defp bump_root_count(socket, parent_id) do
    if socket.assigns.status["id"] == parent_id do
      update(socket, :status, &Map.update(&1, "replies_count", 1, fn n -> n + 1 end))
    else
      socket
    end
  end

  defp react(socket, id, kind) do
    case AnglerWeb.Live.Interactions.toggle(socket.assigns.current_profile, id, kind) do
      {:ok, rendered} -> {:noreply, put_rendered(socket, rendered)}
      :error -> {:noreply, socket}
    end
  end

  # The toggled status may be the main post or one of its comments.
  defp put_rendered(socket, rendered) do
    if socket.assigns.status && socket.assigns.status["id"] == rendered["id"] do
      assign(socket, :status, rendered)
    else
      comments =
        Enum.map(socket.assigns.comments, fn c ->
          if c["id"] == rendered["id"], do: rendered, else: c
        end)

      assign(socket, :comments, comments)
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
      <.post_card status={@status} current_user={@current_user} />
      <div class="mt-2 text-xs text-base-content/50">
        <%= if local_account?(@status["account"]) do %>
          Permalink: <a href={@status["url"]} class="link link-hover">{@status["url"]}</a>
        <% else %>
          <a
            href={@status["url"]}
            target="_blank"
            rel="noopener"
            class="link link-primary inline-flex items-center gap-1"
          >
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
            View original on {@status["account"]["acct"] |> String.split("@") |> List.last()}
          </a>
        <% end %>
      </div>

      <section class="mt-6 space-y-3">
        <h2 class="text-sm font-semibold text-base-content/70">
          {length(@comments)} {ngettext("comment", "comments", length(@comments))}
        </h2>

        <.reply_composer
          :if={@current_user}
          form={@reply_form}
          parent_id={@status["id"]}
          placeholder="Write a comment…"
        />

        <p :if={!@current_user} class="text-sm text-base-content/50">
          <.link navigate={~p"/login"} class="link">Log in</.link> to join the conversation.
        </p>

        <p :if={@comments == []} class="text-sm text-base-content/50">
          No comments yet.
        </p>

        <div
          :for={{comment, depth} <- threaded(@comments, @status["id"])}
          class="space-y-2"
          style={"margin-left: #{min(depth, 6) * 1.25}rem"}
        >
          <.post_card
            id={"comment-#{comment["id"]}"}
            status={comment}
            current_user={@current_user}
          />

          <div :if={@current_user} class="pl-1">
            <button
              type="button"
              phx-click="toggle_reply"
              phx-value-id={comment["id"]}
              class="text-xs text-base-content/60 hover:text-primary"
            >
              {if @open_reply == comment["id"], do: "Cancel", else: "Reply"}
            </button>

            <.reply_composer
              :if={@open_reply == comment["id"]}
              form={@reply_form}
              parent_id={comment["id"]}
              placeholder={"Reply to @#{comment["account"]["acct"]}…"}
            />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Inline reply box, used for the top-level composer and per-comment replies.
  # `parent_id` is carried as a hidden field so one `reply` handler serves all.
  attr :form, :any, required: true
  attr :parent_id, :string, required: true
  attr :placeholder, :string, default: "Write a reply…"

  defp reply_composer(assigns) do
    ~H"""
    <.form
      for={@form}
      id={"reply-form-#{@parent_id}"}
      phx-submit="reply"
      class="mt-2 flex flex-col gap-2"
    >
      <input type="hidden" name="reply[parent_id]" value={@parent_id} />
      <textarea
        name="reply[body]"
        rows="2"
        required
        placeholder={@placeholder}
        class="textarea textarea-bordered w-full"
      >{@form[:body].value}</textarea>
      <div class="flex justify-end">
        <button type="submit" class="btn btn-primary btn-sm" phx-disable-with="Posting…">
          Reply
        </button>
      </div>
    </.form>
    """
  end

  # Flatten the comment maps into a depth-tagged, pre-order (parent-then-subtree)
  # list so the template can indent each reply under the one it answers.
  defp threaded(comments, root_id) do
    by_parent = Enum.group_by(comments, & &1["in_reply_to_id"])
    walk(by_parent, root_id, 0)
  end

  defp walk(by_parent, parent_id, depth) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.flat_map(fn c -> [{c, depth} | walk(by_parent, c["id"], depth + 1)] end)
  end
end
