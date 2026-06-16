# Cap ExUnit's concurrency at the Repo pool size so async tests never wait on a
# sandbox connection (each owns one for its duration). Without this, a small
# `POOL_SIZE` on a many-core runner would leave the default `max_cases`
# (= cores × 2) starved of connections.
max_cases = Application.get_env(:angler, Angler.Repo)[:pool_size]

ExUnit.start(max_cases: max_cases)
Ecto.Adapters.SQL.Sandbox.mode(Angler.Repo, :manual)
