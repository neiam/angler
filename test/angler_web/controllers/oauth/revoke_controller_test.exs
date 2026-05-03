defmodule AnglerWeb.OAuth.RevokeControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.OAuth

  defp setup_token do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, %{client: client, secret: secret}} =
      OAuth.register_client(%{
        "client_name" => "RC",
        "redirect_uris" => "https://app.example/cb"
      })

    {:ok, %{access: access}} = OAuth.issue_token(user, client)
    %{access: access, client: client, secret: secret}
  end

  test "revokes a valid token and the bearer becomes unauthorized", %{conn: conn} do
    %{access: access, client: client, secret: secret} = setup_token()

    # Sanity: the token works first.
    assert {:ok, _} = OAuth.lookup_by_access(access)

    resp =
      post(conn, ~p"/oauth/revoke", %{
        "token" => access,
        "client_id" => Integer.to_string(client.id),
        "client_secret" => secret
      })

    assert response(resp, 200) == ""
    assert :error = OAuth.lookup_by_access(access)
  end

  test "200 even for unknown token", %{conn: conn} do
    resp = post(conn, ~p"/oauth/revoke", %{"token" => "no-such-token"})
    assert response(resp, 200) == ""
  end

  test "200 but no revocation when client secret is wrong", %{conn: conn} do
    %{access: access, client: client} = setup_token()

    resp =
      post(conn, ~p"/oauth/revoke", %{
        "token" => access,
        "client_id" => Integer.to_string(client.id),
        "client_secret" => "wrong"
      })

    assert response(resp, 200) == ""
    # Token still valid.
    assert {:ok, _} = OAuth.lookup_by_access(access)
  end
end
