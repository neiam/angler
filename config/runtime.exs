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
        database: System.get_env("POSTGRES_DB") || "diogramos",
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
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]
