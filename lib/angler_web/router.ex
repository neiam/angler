defmodule AnglerWeb.Router do
  use AnglerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AnglerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Adds bearer-auth to a JSON pipeline. Pass `scopes:` to require specific
  # scopes; omit for "any valid bearer is fine".
  pipeline :authenticated do
    plug :accepts, ["json"]
    plug AnglerWeb.Plugs.BearerAuth
  end

  pipeline :authenticated_read do
    plug :accepts, ["json"]
    plug AnglerWeb.Plugs.BearerAuth, scopes: ["read"]
  end

  pipeline :authenticated_write do
    plug :accepts, ["json"]
    plug AnglerWeb.Plugs.BearerAuth, scopes: ["write"]
  end

  pipeline :federation do
    # No :accepts plug — federation peers' Accept headers are inconsistent
    # (some send `*/*`, some send `application/activity+json`, some omit it).
    # Each controller sets the response Content-Type explicitly.
  end

  pipeline :well_known do
    # No :accepts plug — webfinger/host-meta clients vary wildly.
  end

  scope "/", AnglerWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Federation discovery (.well-known + nodeinfo + instance actor + webfinger).
  # All unauthenticated, all part of the unversioned surface.
  scope "/", AnglerWeb do
    pipe_through :well_known

    get "/.well-known/webfinger", Federation.WebfingerController, :show
    get "/.well-known/nodeinfo", Federation.NodeinfoController, :well_known
    get "/.well-known/host-meta", Federation.HostMetaController, :show
    get "/.well-known/change-password", PageController, :redirect_to_password_settings
  end

  scope "/", AnglerWeb do
    pipe_through :api

    get "/api/nodeinfo/2.0.json", Federation.NodeinfoController, :document
    get "/api/service/health-check", HealthController, :show

    post "/api/auth/app-code-verify", AuthController, :app_code_verify
    post "/api/auth/onboarding", AuthController, :onboarding
  end

  scope "/", AnglerWeb do
    pipe_through :federation

    get "/i/actor", Federation.InstanceActorController, :show
    post "/i/actor/inbox", Federation.InstanceActorController, :inbox
    get "/i/actor/outbox", Federation.InstanceActorController, :outbox

    # User-facing AP actor docs and inboxes.
    get "/users/:username", Federation.UserActorController, :show
    post "/users/:username/inbox", Federation.InboxController, :user

    # Shared inbox for activities addressed to multiple local users.
    post "/f/inbox", Federation.InboxController, :shared
  end

  # Authenticated Mastodon-API surface. Filled out incrementally per grouping.
  scope "/api/v1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_read

    get "/accounts/verify_credentials", AccountController, :verify_credentials
    get "/accounts/relationships", AccountController, :relationships
    get "/statuses/:id", StatusController, :show

    get "/timelines/home", TimelineController, :home
    get "/timelines/public", TimelineController, :public
    get "/timelines/tag/:hashtag", TimelineController, :hashtag
  end

  scope "/api/v1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_write

    post "/statuses", StatusController, :create

    post "/statuses/:id/favourite", StatusController, :favourite
    post "/statuses/:id/unfavourite", StatusController, :unfavourite
    post "/statuses/:id/reblog", StatusController, :reblog
    post "/statuses/:id/unreblog", StatusController, :unreblog
    post "/statuses/:id/bookmark", StatusController, :bookmark
    post "/statuses/:id/unbookmark", StatusController, :unbookmark

    post "/accounts/:id/follow", AccountController, :follow
    post "/accounts/:id/unfollow", AccountController, :unfollow
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:angler, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AnglerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
