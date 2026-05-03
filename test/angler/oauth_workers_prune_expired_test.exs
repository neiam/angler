defmodule Angler.OAuth.Workers.PruneExpiredTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.OAuth
  alias Angler.OAuth.{AuthorizationCode, Token}
  alias Angler.OAuth.Workers.PruneExpired

  defp register! do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    user
  end

  defp register_client! do
    {:ok, %{client: client}} =
      OAuth.register_client(%{
        "client_name" => "T",
        "redirect_uris" => "https://app.example/cb"
      })

    client
  end

  test "deletes authorization codes whose expires_at is more than a day old" do
    user = register!()
    client = register_client!()

    {:ok, %{row: stale}} =
      OAuth.create_authorization_code(user, client, ["read"],
        redirect_uri: "https://app.example/cb"
      )

    {:ok, %{row: fresh}} =
      OAuth.create_authorization_code(user, client, ["read"],
        redirect_uri: "https://app.example/cb"
      )

    Repo.update_all(
      from(c in AuthorizationCode, where: c.id == ^stale.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)]
    )

    assert :ok = perform_job(PruneExpired, %{})

    ids = Repo.all(from c in AuthorizationCode, select: c.id)
    assert ids == [fresh.id]
  end

  test "deletes tokens revoked more than 90 days ago" do
    user = register!()
    client = register_client!()

    {:ok, %{token: stale}} = OAuth.issue_token(user, client)
    {:ok, %{token: live}} = OAuth.issue_token(user, client)

    long_ago = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)

    Repo.update_all(
      from(t in Token, where: t.id == ^stale.id),
      set: [revoked_at: long_ago, last_used_at: long_ago]
    )

    assert :ok = perform_job(PruneExpired, %{})

    ids = Repo.all(from t in Token, select: t.id)
    assert ids == [live.id]
  end

  test "leaves recent revoked tokens alone" do
    user = register!()
    client = register_client!()
    {:ok, %{token: t}} = OAuth.issue_token(user, client)
    OAuth.revoke(t)

    assert :ok = perform_job(PruneExpired, %{})

    [reloaded] = Repo.all(Token)
    assert reloaded.id == t.id
  end
end
