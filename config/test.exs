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
  database: "angler_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

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
