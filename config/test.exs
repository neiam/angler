import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :angler, Angler.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
  database: "angler_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # One sandbox connection per concurrent async test. Defaults to the core
  # count (matches ExUnit's `max_cases`), but on a many-core CI runner that can
  # exceed Postgres' `max_connections` (default 100) — cap it there with
  # `POOL_SIZE`. `test_helper.exs` keeps `max_cases` in lockstep.
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "#{System.schedulers_online() * 2}")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :angler, AnglerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0tYUGzPzdoiVKAuf8t4d/8f4gpS7wTuanGznkzNopkbAiLhmkHsfiYcCD34PUK1L",
  server: false

# In test we don't send emails
config :angler, Angler.Mailer, adapter: Swoosh.Adapters.Test

config :angler, :mail_from, address: "noreply@localhost", name: "Pixelfed"

# Lets Angler.Federation.HTTP allow http:// and 127.0.0.1 (Bypass uses both).
# In dev/prod this is :prod and the SSRF + scheme guards stay strict.
config :angler, :env, :test

# Oban runs in :manual mode in test so jobs only execute when the test drains them.
config :angler, Oban, testing: :manual

# WebPush in tests: the test sender accumulates payloads in :persistent_term
# instead of hitting an HTTP endpoint. VAPID is set to a fixed-but-valid keypair
# so `Vapid.enabled?/0` returns true and the worker actually fires.
config :angler, :push_sender, Angler.Push.Sender.Test

config :web_push_encryption, :vapid_details,
  subject: "mailto:test@angler.local",
  public_key:
    "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U",
  private_key: "vG7C3fb6_OpgL1Kx3p5kJI0nSCwTUKlGqrHL8pV3SWE"

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
