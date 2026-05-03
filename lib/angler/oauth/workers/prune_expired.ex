defmodule Angler.OAuth.Workers.PruneExpired do
  @moduledoc """
  Daily housekeeping for OAuth + auth tables.

  Deletes:
    * `oauth_authorization_codes` whose `expires_at` is over a day in the past
      (covers both unredeemed-and-expired and redeemed-and-stale rows).
    * `app_registers` whose `inserted_at` is over 2 days old (codes expire
      after 24h; we keep one extra day for forensic visibility).
    * `oauth_tokens` revoked more than 90 days ago **and** unused for the
      same window (keeps a recent revocation log for incident response).
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query, warn: false

  alias Angler.Auth.AppRegister
  alias Angler.OAuth.{AuthorizationCode, Token}
  alias Angler.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    code_cutoff = DateTime.add(now, -1 * 86_400, :second)
    register_cutoff = DateTime.add(now, -2 * 86_400, :second)
    token_cutoff = DateTime.add(now, -90 * 86_400, :second)

    {codes, _} =
      from(c in AuthorizationCode, where: c.expires_at < ^code_cutoff)
      |> Repo.delete_all()

    {registers, _} =
      from(r in AppRegister, where: r.inserted_at < ^register_cutoff)
      |> Repo.delete_all()

    {tokens, _} =
      from(t in Token,
        where:
          not is_nil(t.revoked_at) and t.revoked_at < ^token_cutoff and
            (is_nil(t.last_used_at) or t.last_used_at < ^token_cutoff)
      )
      |> Repo.delete_all()

    :telemetry.execute(
      [:angler, :oauth, :prune],
      %{authorization_codes: codes, app_registers: registers, tokens: tokens}
    )

    :ok
  end
end
