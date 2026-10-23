import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/angler start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :angler, AnglerWeb.Endpoint, server: true
end

config :angler, AnglerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Prefer discrete POSTGRES_* env vars (composes safely even when the
  # password contains URL-significant characters like @ / : + & — which
  # is common with StackGres / KubeDB-generated passwords). Fall back to
  # DATABASE_URL when those aren't present.
  cond do
    System.get_env("POSTGRES_HOST") ->
      config :angler, Angler.Repo,
        hostname: System.get_env("POSTGRES_HOST"),
        port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
        username:
          System.get_env("POSTGRES_USER") ||
            raise("POSTGRES_USER is required when POSTGRES_HOST is set"),
        password:
          System.get_env("POSTGRES_PASSWORD") ||
            raise("POSTGRES_PASSWORD is required when POSTGRES_HOST is set"),
        database: System.get_env("POSTGRES_DB") || "angler",
        pool_size: pool_size,
        socket_options: maybe_ipv6

    System.get_env("DATABASE_URL") ->
      config :angler, Angler.Repo,
        url: System.get_env("DATABASE_URL"),
        pool_size: pool_size,
        socket_options: maybe_ipv6

    true ->
      raise """
      Database configuration missing. Set either:
        - POSTGRES_HOST + POSTGRES_USER + POSTGRES_PASSWORD (preferred), or
        - DATABASE_URL (e.g. ecto://USER:PASS@HOST/DATABASE)
      """
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :angler, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # libcluster — Kubernetes endpoints lookup against the headless
  # service we deploy alongside the app. RBAC (pods + endpoints) is
  # granted to the `angler` ServiceAccount in app.yml.
  config :libcluster,
    topologies: [
      angler: [
        strategy: Cluster.Strategy.Kubernetes,
        config: [
          mode: :ip,
          # Both keys are required by libcluster 3.5 even in :endpoints
          # lookup mode — it filters endpoints by selector.
          kubernetes_selector: "name=angler",
          kubernetes_service_name: "angler-headless",
          kubernetes_node_basename: "angler",
          kubernetes_namespace: "angler",
          polling_interval: 10_000
        ]
      ]
    ]

  # Run pending migrations automatically on boot (after the Repo starts, before
  # Oban / the Endpoint) so a fresh deploy is serving with no separate
  # `bin/migrate` step. Opt out with SKIP_MIGRATIONS=true to run migrations
  # yourself (e.g. a dedicated pre-deploy job). dev/test never auto-migrate —
  # they use `mix ecto.migrate` / the Ecto sandbox.
  config :angler, :auto_migrate, System.get_env("SKIP_MIGRATIONS") != "true"

  config :angler, AnglerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :angler, AnglerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :angler, AnglerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# Mailer configuration applies to dev, prod, and any deployed environment.
# In test, config/test.exs forces Swoosh.Adapters.Test and this block is skipped.
#
# Set MAIL_DRIVER=smtp + SMTP_* env vars to send real email. Default "local"
# captures messages in Swoosh's local mailbox preview (visible at /dev/mailbox
# in dev). Setting MAIL_DRIVER=smtp without SMTP_RELAY raises immediately rather
# than silently dropping mail.
#
# Required when MAIL_DRIVER=smtp:
#   SMTP_RELAY         — server hostname (e.g. smtp.example.com)
# Optional auth (omit for open relays):
#   SMTP_USERNAME, SMTP_PASSWORD
# Tunables:
#   SMTP_PORT          — default 587
#   SMTP_TLS           — "always" | "if_available" | "never"; default "if_available"
#   SMTP_AUTH          — "always" | "if_available" | "never"; default "always"
#   SMTP_SSL           — "true" for SMTPS port 465; default false
#   SMTP_RETRIES       — connection retry count; default 2
#   SMTP_NO_MX_LOOKUPS — "true" to skip MX lookup; default false
#   MAIL_FROM          — From: address; default "noreply@<host>"
#   MAIL_FROM_NAME     — From: display name; default "Pixelfed"

if config_env() != :test do
  case System.get_env("MAIL_DRIVER", "local") do
    "smtp" ->
      relay =
        System.get_env("SMTP_RELAY") ||
          raise """
          MAIL_DRIVER=smtp but SMTP_RELAY is not set.
          Set SMTP_RELAY=smtp.example.com (and SMTP_USERNAME/SMTP_PASSWORD if your
          relay requires auth). See config/runtime.exs for the full list of vars.
          """

      smtp_config =
        [
          adapter: Swoosh.Adapters.SMTP,
          relay: relay,
          port: String.to_integer(System.get_env("SMTP_PORT", "587")),
          tls: System.get_env("SMTP_TLS", "if_available") |> String.to_atom(),
          auth: System.get_env("SMTP_AUTH", "always") |> String.to_atom(),
          ssl: System.get_env("SMTP_SSL") in ["true", "1"],
          retries: String.to_integer(System.get_env("SMTP_RETRIES", "2")),
          no_mx_lookups: System.get_env("SMTP_NO_MX_LOOKUPS") in ["true", "1"]
        ]
        |> then(fn cfg ->
          case System.get_env("SMTP_USERNAME") do
            n when n in [nil, ""] ->
              cfg

            user ->
              Keyword.merge(cfg, username: user, password: System.get_env("SMTP_PASSWORD", ""))
          end
        end)

      config :angler, Angler.Mailer, smtp_config

    "local" ->
      config :angler, Angler.Mailer, adapter: Swoosh.Adapters.Local

    other ->
      raise "Unknown MAIL_DRIVER=#{inspect(other)}; expected \"smtp\" or \"local\""
  end

  default_host =
    case Application.get_env(:angler, AnglerWeb.Endpoint) do
      nil -> "localhost"
      cfg -> Keyword.get(cfg[:url] || [], :host, "localhost")
    end

  config :angler, :mail_from,
    address: System.get_env("MAIL_FROM", "noreply@#{default_host}"),
    name: System.get_env("MAIL_FROM_NAME", "Pixelfed")
end

# --------------------------------------------------------------------
# Instance / feature flags
#
# Read at runtime in dev, prod, and any deployed environment. Skipped in
# :test so suite defaults stay deterministic. Tests that need to flip a
# flag use `Application.put_env/3` in their setup.
#
# Boolean env vars accept "true"/"1"/"yes" (case-insensitive); anything
# else parses as the documented default.
# --------------------------------------------------------------------

if config_env() != :test do
  bool = fn key, default ->
    case System.get_env(key) do
      nil -> default
      v -> String.downcase(v) in ["true", "1", "yes"]
    end
  end

  str = fn key, default ->
    case System.get_env(key) do
      nil -> default
      "" -> default
      v -> v
    end
  end

  list = fn key ->
    case System.get_env(key) do
      nil -> []
      "" -> []
      v -> v |> String.split(~r/\s*\|\s*|\n/) |> Enum.reject(&(&1 == ""))
    end
  end

  ## Feature toggles
  config :angler,
    stories_enabled: bool.("STORIES_ENABLED", false),
    groups_enabled: bool.("GROUPS_ENABLED", false),
    open_registration: bool.("OPEN_REGISTRATION", true),
    registration_approval_required: bool.("REGISTRATION_APPROVAL_REQUIRED", true),
    in_app_registration_enabled: bool.("IN_APP_REGISTRATION_ENABLED", true),
    account_deletion_enabled: bool.("ACCOUNT_DELETION_ENABLED", true),
    landing_directory_enabled: bool.("LANDING_DIRECTORY_ENABLED", false),
    landing_explore_enabled: bool.("LANDING_EXPLORE_ENABLED", true),
    expo_push_enabled: bool.("EXPO_PUSH_ENABLED", false),
    oauth_refresh_tokens: bool.("OAUTH_REFRESH_TOKENS", true)

  ## Instance metadata (surfaced via /api/v1/instance, /nodeinfo, etc.)
  config :angler,
    instance_title: str.("INSTANCE_TITLE", "Angler"),
    instance_short_description: str.("INSTANCE_SHORT_DESCRIPTION", nil),
    instance_description: str.("INSTANCE_DESCRIPTION", nil),
    instance_banner_url: str.("INSTANCE_BANNER_URL", nil),
    instance_contact_email: str.("INSTANCE_CONTACT_EMAIL", nil),
    instance_contact_username: str.("INSTANCE_CONTACT_USERNAME", nil),
    instance_rules: list.("INSTANCE_RULES")

  ## Media storage
  storage =
    case String.downcase(System.get_env("MEDIA_STORAGE", "local")) do
      "local" ->
        :local

      "s3" ->
        :s3

      other ->
        raise "Unknown MEDIA_STORAGE=#{inspect(other)}; expected \"local\" or \"s3\""
    end

  config :angler,
    media_storage: storage,
    # Uploads live OUTSIDE priv/static: that dir is `Plug.Static`'s domain (and
    # asset-tooling's), and serving media from there collides with the
    # `/storage/*` router route (Plug.Static intercepts + raises). Media is
    # served by `AnglerWeb.MediaController.serve` from this root instead.
    media_root: str.("MEDIA_ROOT", "priv/uploads")

  ## Pixelfed directory submission (off by default)
  config :angler,
    pixelfed_directory: bool.("PIXELFED_DIRECTORY_ENABLED", false),
    pixelfed_directory_sk: System.get_env("PIXELFED_DIRECTORY_SK")

  ## Web Push (VAPID). Public key is surfaced to the FE so it can build
  ## the subscription. Both keys + subject are what Angler.Push.WebPush
  ## signs deliveries with. If no VAPID is configured, push delivery is a
  ## no-op (config/test.exs configures a fixed test keypair).
  case {System.get_env("PUSH_VAPID_PUBLIC_KEY"), System.get_env("PUSH_VAPID_PRIVATE_KEY")} do
    {pub, priv} when is_binary(pub) and is_binary(priv) and pub != "" and priv != "" ->
      config :angler, push_vapid_public_key: pub

      config :angler, :vapid_details,
        subject: System.get_env("PUSH_VAPID_SUBJECT", "mailto:admin@localhost"),
        public_key: pub,
        private_key: priv

    _ ->
      :ok
  end
end

# Oban configuration. The DB-backed adapter uses our existing Repo.
config :angler, Oban,
  repo: Angler.Repo,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.PG,
  queues: [
    default: 10,
    mailers: 5,
    federation_inbound: 25,
    federation_outbound: 50,
    feed: 20,
    media: 10,
    notifications: 10,
    cleanup: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"15 3 * * *", Angler.OAuth.Workers.PruneExpired},
       {"* * * * *", Angler.Statuses.Workers.ScheduledFire},
       {"* * * * *", Angler.Stories.Workers.Expire},
       # No-op unless Beagle discovery is enabled (see below).
       {"0 * * * *", Angler.Discover.Workers.BeagleDiscover}
     ]}
  ]

# Opt in to the Beagle network-discovery poller (beagle.pixelfed.net). Off
# unless explicitly enabled — it's an outbound call to a third-party service.
if System.get_env("BEAGLE_DISCOVER_ENABLED") in ~w(true 1) do
  config :angler, Angler.Discover.Beagle, enabled: true
end
