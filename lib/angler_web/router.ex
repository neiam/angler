defmodule AnglerWeb.Router do
  use AnglerWeb, :router

  pipeline :browser do
    # Serve AP JSON for `/p/:username/:id` to federation peers before the
    # `:accepts, ["html"]` plug would 406 their `application/activity+json`.
    plug AnglerWeb.Plugs.APObjectNegotiation
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AnglerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :browser_session do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AnglerWeb.Plugs.SessionAuth
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

  pipeline :admin_read do
    plug :accepts, ["json"]
    plug AnglerWeb.Plugs.BearerAuth
    plug AnglerWeb.Plugs.AdminAuth, role: :moderator
  end

  pipeline :admin_write do
    plug :accepts, ["json"]
    plug AnglerWeb.Plugs.BearerAuth
    plug AnglerWeb.Plugs.AdminAuth, role: :admin
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

    live_session :public, on_mount: {AnglerWeb.LiveAuth, :mount_current_user} do
      live "/", IndexLive
      live "/about", AboutLive
      live "/features", FeaturesLive
      live "/login", LoginLive
      live "/register", RegisterLive
      live "/forgot-password", ForgotPasswordLive
      live "/reset-password/:token", ResetPasswordLive
      live "/settings/profile", ProfileEditLive
      live "/search", SearchLive
      live "/tags/:name", TagLive
      live "/@:username", ProfileLive
      live "/@:username/followers", ProfileFollowsLive, :followers
      live "/@:username/following", ProfileFollowsLive, :following
      live "/p/:username/:id", StatusLive
    end

    live_session :admin, on_mount: {AnglerWeb.LiveAuth, :require_admin} do
      live "/admin", AdminSettingsLive
    end
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

    # Public type-ahead backing the navbar search box (accounts + hashtags).
    get "/search/suggest", SearchController, :suggest

    post "/api/auth/app-code-verify", AuthController, :app_code_verify
    post "/api/auth/onboarding", AuthController, :onboarding

    post "/api/v1/apps", MastodonAPI.AppController, :create
    get "/api/v1/instance", MastodonAPI.InstanceController, :show_v1
    get "/api/v1/instance/peers", MastodonAPI.InstanceController, :peers
    get "/api/v2/instance", MastodonAPI.InstanceController, :show_v2
    get "/api/v2/streaming/config", StreamingController, :config
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

    # AP object representation of a published story; bearer-cap gated.
    get "/stories/:username/:id", Federation.StoryObjectController, :show
  end

  # Authenticated Mastodon-API surface. Filled out incrementally per grouping.
  scope "/api/v1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_read

    get "/accounts/verify_credentials", AccountController, :verify_credentials
    get "/accounts/relationships", AccountController, :relationships
    get "/accounts/lookup", AccountController, :lookup
    get "/accounts/search", AccountController, :search
    get "/accounts/:id", AccountController, :show
    get "/accounts/:id/statuses", AccountController, :statuses
    get "/accounts/:id/followers", AccountController, :followers
    get "/accounts/:id/following", AccountController, :following
    get "/accounts/:id/pinned", AccountController, :pinned
    get "/accounts/:id/lists", AccountController, :account_lists
    get "/accounts/:id/identity_proofs", EmptyController, :empty_array

    get "/statuses/:id", StatusController, :show
    get "/statuses/:id/context", StatusController, :context
    get "/statuses/:id/history", StatusController, :history
    get "/statuses/:id/source", StatusController, :source
    get "/statuses/:id/card", StatusController, :card
    get "/statuses/:id/reblogged_by", StatusController, :reblogged_by
    get "/statuses/:id/favourited_by", StatusController, :favourited_by

    get "/timelines/home", TimelineController, :home
    get "/timelines/public", TimelineController, :public
    get "/timelines/tag/:hashtag", TimelineController, :hashtag

    get "/notifications", NotificationController, :index
    get "/notifications/:id", NotificationController, :show

    get "/media/:id", MediaController, :show

    get "/blocks", AccountController, :blocks
    get "/mutes", AccountController, :mutes
    get "/follow_requests", AccountController, :follow_requests

    get "/scheduled_statuses", ScheduledStatusController, :index
    get "/scheduled_statuses/:id", ScheduledStatusController, :show

    get "/polls/:id", PollController, :show

    get "/conversations", ConversationController, :index
    get "/timelines/direct", ConversationController, :direct_timeline

    get "/trends", TrendsController, :unified
    get "/trends/tags", TrendsController, :tags
    get "/trends/statuses", TrendsController, :statuses
    get "/trends/links", TrendsController, :links

    # Mobile bootstrap reads.
    get "/preferences", PreferencesController, :show
    get "/markers", MarkerController, :index
    get "/favourites", AccountListsController, :favourites
    get "/bookmarks", AccountListsController, :bookmarks

    get "/lists", ListController, :index
    get "/lists/:id", ListController, :show
    get "/lists/:id/accounts", ListController, :accounts
    get "/timelines/list/:id", ListController, :timeline

    get "/followed_tags", TagController, :followed
    get "/tags/:id/related", TagController, :related
    get "/tags/:id", TagController, :show

    get "/domain_blocks", DomainBlockController, :index
    get "/announcements", AnnouncementController, :index
    get "/featured_tags", FeaturedTagController, :index
    get "/accounts/:id/featured_tags", FeaturedTagController, :for_account

    get "/discover/posts", DiscoverController, :for_you

    # v1 legacy filter endpoint (flattened shape).
    get "/filters", FilterController, :index_v1

    # Stubs the Mastodon mobile clients call but we don't yet implement.
    get "/endorsements", EmptyController, :empty_array
    get "/suggestions", EmptyController, :empty_array
    get "/custom_emojis", EmptyController, :empty_array
  end

  scope "/api/v2", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_read

    get "/filters", FilterController, :index
    get "/filters/:id", FilterController, :show
    get "/suggestions", EmptyController, :empty_array
  end

  scope "/api/v2", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_write

    post "/filters", FilterController, :create
    put "/filters/:id", FilterController, :update
    delete "/filters/:id", FilterController, :delete
  end

  # Pixelfed v1.1 namespace — bootstrap reads + a few user-initiated actions.
  scope "/api/v1.1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_read

    get "/accounts/login-activity", ApiV1Dot1Controller, :login_activity
    get "/accounts/two-factor", ApiV1Dot1Controller, :two_factor
    get "/accounts/emails-from-pixelfed", ApiV1Dot1Controller, :emails_from_pixelfed
    get "/accounts/apps-and-applications", ApiV1Dot1Controller, :apps_and_applications
    get "/accounts/mutuals/:id", ApiV1Dot1Controller, :mutuals
    get "/accounts/username/:username", ApiV1Dot1Controller, :username_to_id
    get "/accounts/:id/posts", ApiV1Dot1Controller, :posts

    get "/discover/accounts/popular", DiscoverController, :accounts_popular
    get "/discover/posts/trending", DiscoverController, :trending_posts
    get "/discover/posts/hashtags", DiscoverController, :trending_hashtags
    get "/discover/posts/network/trending", DiscoverController, :network_trending

    get "/web/settings", SettingsController, :get_web
    get "/app/settings", SettingsController, :get_app
    get "/compose/settings", SettingsController, :compose

    get "/archive/list", ApiV1Dot1Controller, :archive_list

    get "/direct/compose/mutuals", DirectComposeController, :mutuals

    get "/places/posts/:id/:slug", PlacesController, :show
    get "/compose/search/location", PlacesController, :search_location

    get "/collections/accounts/:id", CollectionController, :for_account
    get "/collections/items/:id", CollectionController, :items
    get "/collections/view/:id", CollectionController, :view
    get "/collections/self", CollectionController, :for_self

    get "/direct/thread", DirectThreadController, :thread

    get "/stories/carousel", StoriesController, :carousel
    get "/stories/self-carousel", StoriesController, :self_carousel
    get "/stories/viewers", StoriesController, :viewers

    # Pixelfed Expo push subscription. State endpoint is GET; the rest
    # are POSTs and live in the write block below.
    get "/push/state", PushExpoController, :state

    # Soft-nag flag — mobile UI uses it to decide whether to surface the
    # "enable notifications" prompt. Read-only.
    get "/nag/state", ApiV1Dot1Controller, :nag_state

    # Legacy alias used by older mobile builds — same as Mastodon
    # `/api/v1/timelines/home`.
    get "/accounts/timelines/home", TimelineController, :home
  end

  # Anonymous landing directory.
  scope "/api/v1.1", AnglerWeb.MastodonAPI do
    pipe_through :api

    get "/landing/v1/directory", DirectoryController, :index
    get "/landing/v1/explore", DirectoryController, :explore

    # Pixelfed federation directory submission. Unauthenticated; gated by
    # an operator-set submission key (`sk`) compared in constant time.
    get "/directory/listing", DirectoryController, :listing

    # In-app registration (anonymous; requires X-PIXELFED-APP header on
    # POSTs). Operators must set both `:open_registration` and
    # `:in_app_registration_enabled` to allow the flow.
    get "/auth/iarpfc", IarController, :preflight
    post "/auth/iar", IarController, :initiate
    get "/auth/iarer", IarController, :email_redirect
    post "/auth/iarc", IarController, :confirm

    # Pre-registration validation against admin-issued invite codes. All
    # three endpoints are anonymous — they're called before the user has
    # an account. Operators seed `admin_invites` rows out-of-band.
    post "/auth/invite/admin/verify", AdminInviteController, :verify
    post "/auth/invite/admin/uc", AdminInviteController, :username_check
    post "/auth/invite/admin/ec", AdminInviteController, :email_check
  end

  scope "/api/v1.1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_write

    delete "/accounts/avatar", ApiV1Dot1Controller, :delete_avatar
    delete "/accounts/header", ApiV1Dot1Controller, :delete_header
    post "/accounts/change-password", ApiV1Dot1Controller, :change_password
    post "/accounts/email", ApiV1Dot1Controller, :change_email
    post "/accounts/disable", ApiV1Dot1Controller, :disable_account
    post "/accounts/delete", ApiV1Dot1Controller, :delete_account
    post "/report", ApiV1Dot1Controller, :report

    post "/web/settings", SettingsController, :set_web
    post "/app/settings", SettingsController, :set_app

    post "/archive/add/:id", ApiV1Dot1Controller, :archive_add
    post "/archive/remove/:id", ApiV1Dot1Controller, :archive_remove

    post "/direct/lookup", DirectComposeController, :lookup

    post "/collections/add", CollectionController, :add
    post "/collections/update/:id", CollectionController, :update
    delete "/collections/delete/:id", CollectionController, :delete
    post "/collections/store_id", CollectionController, :store_id
    post "/collections/remove", CollectionController, :delete_id

    post "/direct/thread/send", DirectThreadController, :send
    delete "/direct/thread/message", DirectThreadController, :delete_message
    post "/direct/thread/read", DirectThreadController, :read
    post "/direct/thread/mute", DirectThreadController, :mute
    post "/direct/thread/unmute", DirectThreadController, :unmute
    post "/direct/thread/media", DirectThreadController, :upload_media

    post "/stories/add", StoriesController, :add
    post "/stories/publish", StoriesController, :publish
    post "/stories/seen", StoriesController, :seen
    post "/stories/self-expire/:id", StoriesController, :self_expire
    post "/stories/comment", StoriesController, :comment

    # Pixelfed Expo push subscription writes.
    post "/push/compare", PushExpoController, :compare
    post "/push/update", PushExpoController, :update
    post "/push/disable", PushExpoController, :disable

    # Pixelfed-shape one-shot status creation: file + caption in a single
    # multipart POST. Mounts on top of `Statuses.create_local/2` so feed
    # fanout and federation behave identically to the Mastodon path.
    post "/status/create", ApiV1Dot1Controller, :status_create_pixelfed
  end

  # `v1.2/stories/...` — newer story endpoints (overlays-aware composer
  # flow + carousel `next` page + mention autocomplete). Pixelfed split
  # these out from v1.1 so older clients aren't forced to learn the new
  # publish shape; we mount them on the same controllers but a separate
  # action namespace to keep that boundary clean.
  scope "/api/v1.2", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_read

    get "/stories/carousel", StoriesV12Controller, :carousel_next
    get "/stories/mention-autocomplete", StoriesV12Controller, :mention_autocomplete
  end

  scope "/api/v1.2", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_write

    post "/stories/publish", StoriesV12Controller, :publish_next
  end

  # `pixelfed/v1` — legacy Pixelfed prefix. The mobile clients hit either
  # this or `v1.1`; same controllers, same behaviour. Endpoints exclusive
  # to one namespace in upstream Pixelfed (e.g. iar/auth, push/*, mutuals,
  # network/trending) are NOT mirrored — those stay v1.1-only.
  scope "/api/pixelfed/v1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_read

    get "/accounts/timelines/home", TimelineController, :home
    get "/accounts/login-activity", ApiV1Dot1Controller, :login_activity
    get "/accounts/two-factor", ApiV1Dot1Controller, :two_factor
    get "/accounts/emails-from-pixelfed", ApiV1Dot1Controller, :emails_from_pixelfed
    get "/accounts/apps-and-applications", ApiV1Dot1Controller, :apps_and_applications
    get "/accounts/:id/posts", ApiV1Dot1Controller, :posts

    get "/archive/list", ApiV1Dot1Controller, :archive_list

    get "/collections/accounts/:id", CollectionController, :for_account
    get "/collections/items/:id", CollectionController, :items
    get "/collections/view/:id", CollectionController, :view
    get "/collections/self", CollectionController, :for_self

    get "/compose/search/location", PlacesController, :search_location
    get "/compose/settings", SettingsController, :compose

    get "/direct/thread", DirectThreadController, :thread

    get "/discover/accounts/popular", DiscoverController, :accounts_popular
    get "/discover/posts/trending", DiscoverController, :trending_posts
    get "/discover/posts/hashtags", DiscoverController, :trending_hashtags

    get "/places/posts/:id/:slug", PlacesController, :show

    get "/web/settings", SettingsController, :get_web
    get "/app/settings", SettingsController, :get_app

    get "/stories/carousel", StoriesController, :carousel
    get "/stories/self-carousel", StoriesController, :self_carousel
    get "/stories/viewers", StoriesController, :viewers
  end

  scope "/api/pixelfed/v1", AnglerWeb.MastodonAPI do
    pipe_through :api

    get "/directory/listing", DirectoryController, :listing
  end

  scope "/api/pixelfed/v1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_write

    post "/report", ApiV1Dot1Controller, :report

    delete "/accounts/avatar", ApiV1Dot1Controller, :delete_avatar
    delete "/accounts/header", ApiV1Dot1Controller, :delete_header
    post "/accounts/change-password", ApiV1Dot1Controller, :change_password
    post "/accounts/email", ApiV1Dot1Controller, :change_email
    post "/accounts/disable", ApiV1Dot1Controller, :disable_account
    post "/accounts/delete", ApiV1Dot1Controller, :delete_account

    post "/archive/add/:id", ApiV1Dot1Controller, :archive_add
    post "/archive/remove/:id", ApiV1Dot1Controller, :archive_remove

    post "/collections/add", CollectionController, :add
    post "/collections/update/:id", CollectionController, :update
    delete "/collections/delete/:id", CollectionController, :delete
    post "/collections/store_id", CollectionController, :store_id
    post "/collections/remove", CollectionController, :delete_id

    post "/direct/lookup", DirectComposeController, :lookup
    post "/direct/thread/send", DirectThreadController, :send
    delete "/direct/thread/message", DirectThreadController, :delete_message
    post "/direct/thread/read", DirectThreadController, :read
    post "/direct/thread/mute", DirectThreadController, :mute
    post "/direct/thread/unmute", DirectThreadController, :unmute
    post "/direct/thread/media", DirectThreadController, :upload_media

    post "/web/settings", SettingsController, :set_web
    post "/app/settings", SettingsController, :set_app

    post "/stories/add", StoriesController, :add
    post "/stories/publish", StoriesController, :publish
    post "/stories/seen", StoriesController, :seen
    post "/stories/self-expire/:id", StoriesController, :self_expire
    post "/stories/comment", StoriesController, :comment
  end

  scope "/api/v1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated

    get "/apps/verify_credentials", AppController, :verify

    # Push subscription is bound to the OAuth token itself, so any valid bearer
    # may read/write its own subscription regardless of the token's scopes.
    get "/push/subscription", PushSubscriptionController, :show
    post "/push/subscription", PushSubscriptionController, :create
    put "/push/subscription", PushSubscriptionController, :update
    delete "/push/subscription", PushSubscriptionController, :delete
  end

  scope "/api/v1", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_write

    post "/statuses", StatusController, :create

    patch "/accounts/update_credentials", AccountController, :update_credentials
    post "/accounts/update_credentials", AccountController, :update_credentials

    delete "/statuses/:id", StatusController, :delete
    put "/statuses/:id", StatusController, :update

    post "/statuses/:id/pin", StatusController, :pin
    post "/statuses/:id/unpin", StatusController, :unpin

    post "/statuses/:id/favourite", StatusController, :favourite
    post "/statuses/:id/unfavourite", StatusController, :unfavourite
    post "/statuses/:id/reblog", StatusController, :reblog
    post "/statuses/:id/unreblog", StatusController, :unreblog
    post "/statuses/:id/bookmark", StatusController, :bookmark
    post "/statuses/:id/unbookmark", StatusController, :unbookmark

    post "/accounts/:id/follow", AccountController, :follow
    post "/accounts/:id/unfollow", AccountController, :unfollow
    post "/accounts/:id/block", AccountController, :block
    post "/accounts/:id/unblock", AccountController, :unblock
    post "/accounts/:id/mute", AccountController, :mute
    post "/accounts/:id/unmute", AccountController, :unmute
    post "/accounts/:id/remove_from_followers", AccountController, :remove_from_followers
    post "/accounts/:id/pin", AccountController, :endorse
    post "/accounts/:id/unpin", AccountController, :unendorse

    # Pixelfed-only direct avatar upload (mobile clients use it instead
    # of `PATCH /accounts/update_credentials` for solo avatar changes).
    post "/avatar/update", AccountController, :avatar_update
    post "/header/update", AccountController, :header_update

    post "/follow_requests/:id/authorize", AccountController, :authorize_request
    post "/follow_requests/:id/reject", AccountController, :reject_request

    put "/scheduled_statuses/:id", ScheduledStatusController, :update
    delete "/scheduled_statuses/:id", ScheduledStatusController, :delete

    post "/polls/:id/votes", PollController, :vote

    post "/conversations/:id/read", ConversationController, :read
    delete "/conversations/:id", ConversationController, :delete

    post "/markers", MarkerController, :update

    post "/notifications/clear", NotificationController, :clear
    post "/notifications/:id/dismiss", NotificationController, :dismiss

    post "/media", MediaController, :upload_v1
    put "/media/:id", MediaController, :update

    post "/lists", ListController, :create
    put "/lists/:id", ListController, :update
    delete "/lists/:id", ListController, :delete
    post "/lists/:id/accounts", ListController, :add_accounts
    delete "/lists/:id/accounts", ListController, :remove_accounts

    post "/tags/:id/follow", TagController, :follow
    post "/tags/:id/unfollow", TagController, :unfollow

    post "/domain_blocks", DomainBlockController, :create
    delete "/domain_blocks", DomainBlockController, :delete

    post "/announcements/:id/dismiss", AnnouncementController, :dismiss

    post "/featured_tags", FeaturedTagController, :create
    delete "/featured_tags/:id", FeaturedTagController, :delete

    post "/reports", ReportController, :create
  end

  scope "/api/v2", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_write

    post "/media", MediaController, :upload_v2
  end

  scope "/api/v2", AnglerWeb.MastodonAPI do
    pipe_through :authenticated_read

    get "/search", SearchController, :search
  end

  scope "/", AnglerWeb do
    pipe_through :api

    # Legacy Pixelfed media URL fallback redirect — older clients still
    # use this shape. Maps to the standard `/storage/...` serve route.
    # Must come BEFORE the catch-all `/storage/*path` route below.
    get "/storage/m/_v2/:pid/:mhash/:uhash/:f", MediaController, :fallback_redirect

    get "/storage/*path", MediaController, :serve

    post "/oauth/token", OAuth.TokenController, :token
    post "/oauth/revoke", OAuth.RevokeController, :revoke

    # Mastodon-shape streaming (raw WebSocket, not Phoenix.Channel).
    get "/api/v1/streaming", StreamingController, :upgrade
    get "/api/v1/streaming/:type", StreamingController, :upgrade
  end

  ## Admin namespace — moderator+ for read endpoints, admin for writes.

  scope "/api/v1/admin", AnglerWeb.Admin do
    pipe_through :admin_read

    get "/reports", ReportController, :index
    get "/reports/:id", ReportController, :show

    get "/accounts", AccountController, :index
    get "/accounts/:id", AccountController, :show

    get "/domain_blocks", DomainBlockController, :index
    get "/domain_blocks/:id", DomainBlockController, :show

    get "/email_domain_blocks", EmailDomainBlockController, :index

    get "/announcements", AnnouncementController, :index
  end

  scope "/api/v1/admin", AnglerWeb.Admin do
    pipe_through :admin_write

    post "/reports/:id/assign_to_self", ReportController, :assign_to_self
    post "/reports/:id/unassign", ReportController, :unassign
    post "/reports/:id/resolve", ReportController, :resolve
    post "/reports/:id/reopen", ReportController, :reopen

    post "/accounts/:id/action", AccountController, :act
    post "/accounts/:id/approve", AccountController, :approve
    post "/accounts/:id/reject", AccountController, :reject
    post "/accounts/:id/unsuspend", AccountController, :unsuspend
    post "/accounts/:id/unsilence", AccountController, :unsilence
    post "/accounts/:id/enable", AccountController, :enable
    delete "/accounts/:id", AccountController, :delete

    post "/domain_blocks", DomainBlockController, :create
    put "/domain_blocks/:id", DomainBlockController, :update
    delete "/domain_blocks/:id", DomainBlockController, :delete

    post "/email_domain_blocks", EmailDomainBlockController, :create
    delete "/email_domain_blocks/:id", EmailDomainBlockController, :delete

    post "/announcements", AnnouncementController, :create
    put "/announcements/:id", AnnouncementController, :update
    delete "/announcements/:id", AnnouncementController, :delete
  end

  ## Pixelfed `/api/v0/groups/...` — community groups. Whole feature is
  ## gated by the `:groups_enabled` config flag (default false → every
  ## endpoint 404s). Read endpoints are split across four controllers
  ## by theme; writes live in the matching write blocks below.

  scope "/api/v0/groups", AnglerWeb.GroupsAPI do
    pipe_through :authenticated_read

    # Capability + lifecycle reads
    get "/config", GroupsController, :config
    get "/categories/list", GroupsController, :categories_list
    get "/category/list", GroupsController, :category_groups
    get "/discover/popular", GroupsController, :discover_popular
    get "/discover/new", GroupsController, :discover_new
    get "/self/list", GroupsController, :self_list
    get "/self/recommended/list", GroupsController, :self_recommended

    # Members + admin reads
    get "/members/list", GroupsMemberController, :members_list
    get "/members/get", GroupsMemberController, :members_get
    get "/members/requests", GroupsMemberController, :members_requests
    get "/member/intersect/common", GroupsMemberController, :member_intersect_common
    get "/accounts/:gid/:pid", GroupsMemberController, :account_in_group

    # Topics + posts reads
    get "/topics/list", GroupsFeedController, :topics_list
    get "/topics/tag", GroupsFeedController, :topic_tag
    get "/comments", GroupsPostController, :comments_list
    get "/status", GroupsPostController, :get_status
    get "/media/list", GroupsPostController, :media_list

    # Self feeds
    get "/self/feed", GroupsFeedController, :self_feed
    get "/self/notifications", GroupsFeedController, :self_notifications

    # Per-group reads + admin
    get "/search/getrec", GroupsSearchController, :search_getrec
    get "/:id/feed", GroupsFeedController, :group_feed
    get "/:id/user/:pid/feed", GroupsFeedController, :group_profile_feed
    get "/:id/atabs", GroupsAdminController, :admin_tabs
    get "/:id/admin/interactions", GroupsAdminController, :admin_interactions
    get "/:id/admin/blocks", GroupsAdminController, :admin_blocks
    get "/:id/reports/list", GroupsAdminController, :reports_list
    get "/:id/members/interaction-limits", GroupsMemberController, :get_interaction_limits
    get "/:id/likes/:sid", GroupsPostController, :show_status_likes
    get "/:id", GroupsController, :show
  end

  scope "/api/v0/groups", AnglerWeb.GroupsAPI do
    pipe_through :authenticated_write

    # Capability probe + lifecycle
    post "/permission/create", GroupsController, :can_create?
    post "/create", GroupsController, :create
    post "/delete", GroupsController, :delete

    # Search variants
    post "/search/invite/friends/send", GroupsMemberController, :search_invite_send
    post "/search/invite/friends", GroupsMemberController, :search_invite_friends
    post "/search/global", GroupsSearchController, :search_global
    post "/search/lac", GroupsSearchController, :search_lac
    post "/search/addrec", GroupsSearchController, :search_addrec

    # Comments
    post "/comment", GroupsPostController, :store_comment
    post "/comment/photo", GroupsPostController, :store_comment_photo
    post "/comment/delete", GroupsPostController, :delete_comment
    post "/comment/like", GroupsPostController, :comment_like
    post "/comment/unlike", GroupsPostController, :comment_unlike

    # Posts
    post "/status/new", GroupsPostController, :store_post
    post "/status/delete", GroupsPostController, :delete_post
    post "/status/like", GroupsPostController, :like_post
    post "/status/unlike", GroupsPostController, :unlike_post
    post "/like", GroupsPostController, :like_post

    # Members ops
    post "/members/request", GroupsMemberController, :members_request_handle

    # Per-group writes
    post "/:id/invite/check", GroupsMemberController, :invite_check
    post "/:id/invite/accept", GroupsMemberController, :invite_accept
    post "/:id/invite/decline", GroupsMemberController, :invite_decline

    post "/:id/members/interaction-limits",
         GroupsMemberController,
         :update_interaction_limits

    post "/:id/admin/blocks/add", GroupsAdminController, :admin_blocks_add
    post "/:id/admin/blocks/undo", GroupsAdminController, :admin_blocks_undo
    post "/:id/admin/blocks/export", GroupsAdminController, :admin_blocks_export
    post "/:id/admin/mbs", GroupsAdminController, :admin_mbs

    post "/:id/report/action", GroupsAdminController, :report_action
    post "/:id/report/create", GroupsAdminController, :report_create
    post "/:id/join", GroupsMemberController, :join
    post "/:id/cjr", GroupsMemberController, :cancel_join_request
    post "/:id/leave", GroupsMemberController, :leave
    post "/:id/settings", GroupsController, :update
  end

  ## Pixelfed-shape admin namespace at `/api/admin/*`. Distinct from the
  ## Mastodon-shape admin under `/api/v1/admin/*`. Both use the same
  ## auth pipelines (`:admin_read` for moderator+, `:admin_write` for
  ## admin) but expose different response shapes for different consumers.

  scope "/api/admin", AnglerWeb.PixelfedAdmin do
    pipe_through :admin_read

    get "/supported", AdminController, :supported
    get "/stats", AdminController, :stats
    get "/instance/stats", AdminController, :all_stats

    get "/autospam/list", AdminController, :autospam_list
    get "/mod-reports/list", AdminController, :mod_reports_list
    get "/config", AdminController, :config_get

    get "/users/list", AdminController, :users_list
    get "/users/get", AdminController, :users_get

    get "/instances/list", AdminController, :instances_list
    get "/instances/get", AdminController, :instances_get
  end

  scope "/api/admin", AnglerWeb.PixelfedAdmin do
    pipe_through :admin_write

    post "/autospam/handle", AdminController, :autospam_handle
    post "/mod-reports/handle", AdminController, :mod_reports_handle
    post "/config/update", AdminController, :config_update

    post "/users/action", AdminController, :users_action
    post "/instances/moderate", AdminController, :instances_moderate
    post "/instances/refresh-stats", AdminController, :instances_refresh_stats
    post "/moderate/post/:id", AdminController, :moderate_post
  end

  scope "/", AnglerWeb do
    pipe_through :browser_session

    get "/session/login", SessionController, :new
    post "/session/login", SessionController, :create
    post "/session/logout", SessionController, :delete

    get "/oauth/authorize", OAuth.AuthorizeController, :show
    post "/oauth/authorize", OAuth.AuthorizeController, :authorize
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
