defmodule Angler.OAuthTest do
  use Angler.DataCase, async: false

  alias Angler.{Accounts, OAuth}

  setup do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    %{user: user}
  end

  describe "first_party_client!/0" do
    test "is idempotent" do
      a = OAuth.first_party_client!()
      b = OAuth.first_party_client!()
      assert a.client.id == b.client.id
    end
  end

  describe "issue_token/3" do
    test "returns access + refresh + persisted row", %{user: user} do
      %{client: client} = OAuth.first_party_client!()

      assert {:ok, %{access: access, refresh: refresh, token: token}} =
               OAuth.issue_token(user, client)

      assert is_binary(access) and byte_size(access) >= 60
      assert is_binary(refresh) and byte_size(refresh) >= 60
      assert token.user_id == user.id
      assert token.profile_id == user.profile_id
      assert token.scopes == client.scopes
      assert token.expires_at
      refute token.revoked_at
    end

    test "raw access token is not stored verbatim", %{user: user} do
      %{client: client} = OAuth.first_party_client!()
      {:ok, %{access: access, token: token}} = OAuth.issue_token(user, client)

      refute access == token.token_hash
      assert token.token_hash == :crypto.hash(:sha256, access)
    end
  end

  describe "lookup_by_access/1" do
    test "returns the token row for a valid access string", %{user: user} do
      %{client: client} = OAuth.first_party_client!()
      {:ok, %{access: access}} = OAuth.issue_token(user, client)

      assert {:ok, _token} = OAuth.lookup_by_access(access)
    end

    test "returns :error for unknown token" do
      assert :error = OAuth.lookup_by_access("not-a-real-token")
    end

    test "returns :error for revoked token", %{user: user} do
      %{client: client} = OAuth.first_party_client!()
      {:ok, %{access: access, token: token}} = OAuth.issue_token(user, client)

      Ecto.Changeset.change(token, revoked_at: DateTime.utc_now())
      |> Repo.update!()

      assert :error = OAuth.lookup_by_access(access)
    end

    test "returns :error for expired token", %{user: user} do
      %{client: client} = OAuth.first_party_client!()
      {:ok, %{access: access, token: token}} = OAuth.issue_token(user, client)

      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      Ecto.Changeset.change(token, expires_at: past) |> Repo.update!()

      assert :error = OAuth.lookup_by_access(access)
    end
  end
end
