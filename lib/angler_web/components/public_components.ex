defmodule AnglerWeb.PublicComponents do
  @moduledoc """
  Function components shared by the public web LiveViews (index feed, profile,
  single status). They render an already-built Mastodon-shape status **map**
  (string keys) — the same shape produced by `AnglerWeb.MastodonAPI.Status`
  and broadcast over `Angler.Streaming`, so the initial server render and the
  live `update` payloads render through one path.
  """
  use AnglerWeb, :html

  @doc """
  A single post card: author, caption HTML, media, and a timestamp that deep
  links to the status permalink (`/p/:username/:id`).
  """
  attr :status, :map, required: true, doc: "a rendered Mastodon status map (string keys)"
  attr :id, :string, default: nil

  attr :current_user, :map,
    default: nil,
    doc: "when set, the reblog/favourite footer becomes interactive (phx-click)"

  attr :boost_id, :string,
    default: nil,
    doc: "set internally when `status` is a boost wrapper: the wrapper's id"

  attr :boosted_by, :map,
    default: nil,
    doc: "set internally when `status` is a boost wrapper: the booster's account"

  # A boost (Mastodon wrapper status, `"reblog"` set) renders the boosted post
  # under a "boosted" line. The footer buttons act on the boosted post and
  # carry the wrapper's id as `phx-value-boost`, so the LiveView can re-insert
  # the stream item under the wrapper's DOM id.
  def post_card(%{status: %{"reblog" => %{} = inner} = wrapper} = assigns) do
    assigns
    |> assign(:status, inner)
    |> assign(:boost_id, wrapper["id"])
    |> assign(:boosted_by, wrapper["account"] || %{})
    |> post_card()
  end

  def post_card(assigns) do
    assigns =
      assigns
      |> assign(:account, assigns.status["account"] || %{})
      |> assign(:media, assigns.status["media_attachments"] || [])
      |> assign(:filtered, filtered_info(assigns.status))
      |> assign(:via_tags, assigns.status["_via_tags"] || [])

    ~H"""
    <article id={@id} class="card bg-base-200 border border-base-300">
      <div class="card-body gap-3 p-4">
        <div
          :if={@boosted_by}
          class="-mb-1 flex items-center gap-1.5 text-xs text-base-content/60"
        >
          <.icon name="hero-arrow-path-rounded-square-micro" class="size-4 text-success" />
          <.account_link account={@boosted_by} class="font-medium hover:underline">
            {display_name(@boosted_by)}
          </.account_link>
          boosted
        </div>
        <%!-- Home feed only: in the feed through a followed hashtag rather
             than a followed account (`Timelines.home_tag_sources/2`). --%>
        <div
          :if={@via_tags != []}
          class="via-tags -mb-1 flex flex-wrap items-center gap-x-1.5 text-xs text-base-content/60"
        >
          <.icon name="hero-hashtag-micro" class="size-4 text-primary" />
          <span>via</span>
          <.link
            :for={name <- @via_tags}
            navigate={~p"/tags/#{name}"}
            class="font-medium text-primary hover:underline"
          >
            #{name}
          </.link>
        </div>
        <header class="flex items-center gap-3">
          <.account_link account={@account} class="shrink-0">
            <.avatar account={@account} />
          </.account_link>
          <div class="min-w-0">
            <.account_link account={@account} class="font-semibold hover:underline">
              {display_name(@account)}
            </.account_link>
            <div class="text-xs text-base-content/60 truncate">@{@account["acct"]}</div>
          </div>
          <.link
            navigate={~p"/p/#{@account["username"]}/#{@status["id"]}"}
            class="ml-auto text-xs text-base-content/60 hover:underline whitespace-nowrap"
            title={@status["created_at"]}
          >
            {relative_time(@status["created_at"])}
          </.link>
        </header>

        <%= if @filtered do %>
          <details class="rounded-box overflow-hidden border border-warning/40">
            <summary class="cursor-pointer bg-base-300 px-3 py-2 text-sm">
              <.icon name="hero-eye-slash-micro" class="size-4" />
              Filtered: {@filtered.title} — click to show
            </summary>
            <div class={[
              "space-y-3 p-2",
              @filtered.action == "blur" && "blur-sm transition hover:blur-none"
            ]}>
              <.post_body status={@status} media={@media} />
            </div>
          </details>
        <% else %>
          <.post_body status={@status} media={@media} />
        <% end %>

        <footer class="flex items-center gap-4 text-xs text-base-content/60">
          <.link
            navigate={~p"/p/#{@account["username"]}/#{@status["id"]}"}
            class="flex items-center gap-1 hover:text-base-content"
          >
            <.icon name="hero-chat-bubble-oval-left-micro" class="size-4" />
            {@status["replies_count"] || 0}
          </.link>

          <%= if @current_user do %>
            <button
              type="button"
              phx-click="reblog"
              phx-value-id={@status["id"]}
              phx-value-boost={@boost_id}
              class={[
                "flex items-center gap-1 transition-colors hover:text-success",
                @status["reblogged"] && "text-success font-medium"
              ]}
            >
              <.icon name="hero-arrow-path-rounded-square-micro" class="size-4" />
              {@status["reblogs_count"] || 0}
            </button>
            <button
              type="button"
              phx-click="favourite"
              phx-value-id={@status["id"]}
              phx-value-boost={@boost_id}
              class={[
                "flex items-center gap-1 transition-colors hover:text-error",
                @status["favourited"] && "text-error font-medium"
              ]}
            >
              <.icon name="hero-heart-micro" class="size-4" />
              {@status["favourites_count"] || 0}
            </button>
          <% else %>
            <span class="flex items-center gap-1">
              <.icon name="hero-arrow-path-rounded-square-micro" class="size-4" />
              {@status["reblogs_count"] || 0}
            </span>
            <span class="flex items-center gap-1">
              <.icon name="hero-heart-micro" class="size-4" />
              {@status["favourites_count"] || 0}
            </span>
          <% end %>
        </footer>
      </div>
    </article>
    """
  end

  # The caption + media of a post, shared by the plain and filtered renders.
  attr :status, :map, required: true
  attr :media, :list, required: true

  defp post_body(assigns) do
    ~H"""
    <div :if={@status["spoiler_text"] not in [nil, ""]} class="text-sm font-medium">
      {@status["spoiler_text"]}
    </div>

    <div
      :if={@status["content"] not in [nil, ""]}
      class="post-caption prose prose-sm max-w-none break-words"
    >
      {raw(@status["content"])}
    </div>

    <.media_grid :if={@media != []} media={@media} sensitive={@status["sensitive"]} />
    """
  end

  # Pull the first Mastodon `filtered` entry into a compact `%{action, title}`
  # the card gates on. `hide`-action posts never reach the client, so only
  # `warn`/`blur` show up here.
  defp filtered_info(%{"filtered" => [%{"filter" => filter} | _]}) do
    %{action: filter["filter_action"] || "warn", title: filter["title"] || "filtered"}
  end

  defp filtered_info(_), do: nil

  @doc "Avatar image with an initials fallback when no avatar is set."
  attr :account, :map, required: true
  attr :class, :string, default: "size-10"

  def avatar(assigns) do
    ~H"""
    <%= if avatar_url(@account) do %>
      <img src={avatar_url(@account)} alt="" class={["rounded-full object-cover", @class]} />
    <% else %>
      <div class={[
        "rounded-full bg-neutral text-neutral-content grid place-items-center font-semibold",
        @class
      ]}>
        {initial(@account)}
      </div>
    <% end %>
    """
  end

  @doc "Media attachments grid. Sensitive media is hidden behind a disclosure."
  attr :media, :list, required: true
  attr :sensitive, :boolean, default: false

  def media_grid(assigns) do
    ~H"""
    <%= if @sensitive do %>
      <details class="rounded-box overflow-hidden border border-base-300">
        <summary class="cursor-pointer bg-base-300 px-3 py-2 text-sm">
          <.icon name="hero-eye-slash-micro" class="size-4" /> Sensitive content — click to show
        </summary>
        <.media_tiles media={@media} />
      </details>
    <% else %>
      <.media_tiles media={@media} />
    <% end %>
    """
  end

  attr :media, :list, required: true

  defp media_tiles(assigns) do
    ~H"""
    <div
      data-lightbox-group
      class={[
        "grid gap-1",
        length(@media) > 1 && "grid-cols-2",
        length(@media) == 1 && "grid-cols-1"
      ]}
    >
      <div :for={m <- @media} class="overflow-hidden rounded-box bg-base-300">
        <%= case m["type"] do %>
          <% type when type in ["video", "gifv"] -> %>
            <video controls class="w-full" src={m["url"]} poster={m["preview_url"]} />
          <% _ -> %>
            <%!-- Opens the full-size photo in the viewer (assets/js/lightbox.js). --%>
            <button
              type="button"
              id={"media-#{m["id"]}"}
              data-lightbox-src={m["url"] || m["preview_url"]}
              data-lightbox-alt={m["description"] || ""}
              aria-label={"View photo full size" <> alt_suffix(m["description"])}
              class="group block w-full cursor-zoom-in"
            >
              <img
                src={m["preview_url"] || m["url"]}
                alt={m["description"] || ""}
                loading="lazy"
                class="w-full object-cover transition duration-300 group-hover:scale-[1.02] group-hover:brightness-105"
              />
            </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp alt_suffix(desc) when is_binary(desc) and desc != "", do: ": " <> desc
  defp alt_suffix(_), do: ""

  @doc """
  Segmented control switching between layouts of the same page. Each option
  is a `patch` link (so every layout is its own URL) replacing the history
  entry, so toggling doesn't pile up back-button steps.
  """
  attr :id, :string, required: true

  attr :options, :list,
    required: true,
    doc: "maps with `:id`, `:path`, `:label`, `:icon` and `:active?`"

  def layout_toggle(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-label="Layout"
      class="inline-flex rounded-field border border-base-300 bg-base-200 p-0.5"
    >
      <.link
        :for={opt <- @options}
        id={opt.id}
        patch={opt.path}
        replace
        title={opt.label}
        aria-label={opt.label <> " layout"}
        aria-pressed={to_string(opt.active?)}
        class={[
          "inline-flex items-center justify-center rounded-[calc(var(--radius-field)-2px)] px-2 py-1 transition-colors",
          if(opt.active?,
            do: "bg-base-100 text-base-content shadow-sm",
            else: "text-base-content/60 hover:text-base-content"
          )
        ]}
      >
        <.icon name={opt.icon} class="size-4" />
      </.link>
    </div>
    """
  end

  @doc """
  Masonry-only toggle between showing captions and photos only. `path` is
  where the link goes (the other caption state).
  """
  attr :id, :string, default: "captions-toggle"
  attr :path, :string, required: true
  attr :captions?, :boolean, required: true

  def captions_toggle(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@path}
      replace
      title={if @captions?, do: "Hide captions", else: "Show captions"}
      aria-pressed={to_string(@captions?)}
      class={["btn btn-sm gap-1.5", if(@captions?, do: "btn-ghost", else: "btn-outline")]}
    >
      <.icon
        name={
          if @captions?,
            do: "hero-chat-bubble-bottom-center-text-micro",
            else: "hero-photo-micro"
        }
        class="size-4"
      />
      {if @captions?, do: "Captions", else: "Photos only"}
    </.link>
    """
  end

  @doc """
  Wraps its content in an in-app link to the account's profile. Uses the
  account's `acct` (`username` for local, `username@domain` for remote) so both
  resolve through the cached `/@:acct` profile page; the remote profile page is
  what surfaces the "view original" link out.
  """
  attr :account, :map, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def account_link(assigns) do
    ~H"""
    <.link navigate={~p"/@#{account_acct(@account)}"} class={@class}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc "True when the account map is a local one (no domain in its `acct`)."
  def local_account?(%{"acct" => acct}) when is_binary(acct), do: not String.contains?(acct, "@")
  def local_account?(_), do: true

  defp account_acct(%{"acct" => acct}) when is_binary(acct) and acct != "", do: acct
  defp account_acct(%{"username" => username}), do: username

  @doc """
  A list row for an account: avatar + display name + `@acct`, with a follower
  count. Used by search results and the follower/following lists.
  """
  attr :account, :map, required: true

  def account_row(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body flex-row items-center gap-3 p-3">
        <.account_link account={@account} class="shrink-0">
          <.avatar account={@account} />
        </.account_link>
        <div class="min-w-0 flex-1">
          <.account_link account={@account} class="font-semibold hover:underline">
            {display_name(@account)}
          </.account_link>
          <div class="text-xs text-base-content/60 truncate">@{@account["acct"]}</div>
        </div>
        <div class="text-xs text-base-content/60 whitespace-nowrap tabular-nums">
          {@account["followers_count"]} followers
        </div>
      </div>
    </div>
    """
  end

  ## Helpers

  @doc "Best display label for an account map."
  def display_name(%{"display_name" => name}) when is_binary(name) and name != "", do: name
  def display_name(%{"username" => username}) when is_binary(username), do: username
  def display_name(_), do: "Unknown"

  defp avatar_url(%{"avatar" => url}) when is_binary(url) and url != "", do: url
  defp avatar_url(_), do: nil

  defp initial(%{"username" => <<c::utf8, _::binary>>}), do: <<c::utf8>> |> String.upcase()
  defp initial(_), do: "?"

  @doc """
  Compact relative time ("3m", "5h", "2d") for an ISO8601 timestamp string,
  falling back to a date for anything older than a week.
  """
  def relative_time(nil), do: ""

  def relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> humanize(DateTime.diff(DateTime.utc_now(), dt, :second), dt)
      _ -> iso
    end
  end

  defp humanize(secs, _dt) when secs < 60, do: "now"
  defp humanize(secs, _dt) when secs < 3600, do: "#{div(secs, 60)}m"
  defp humanize(secs, _dt) when secs < 86_400, do: "#{div(secs, 3600)}h"
  defp humanize(secs, _dt) when secs < 604_800, do: "#{div(secs, 86_400)}d"
  defp humanize(_secs, dt), do: Calendar.strftime(dt, "%b %-d, %Y")
end
