defmodule Angler.AccountsTest do
  use Angler.DataCase, async: false

  alias Angler.Accounts
  alias Angler.Accounts.User

  describe "register/1" do
    test "creates a user + profile in a single transaction" do
      assert {:ok, %{user: user, profile: profile}} =
               Accounts.register(%{
                 username: "alice",
                 email: "alice@example.com",
                 password: "verysecret123",
                 name: "Alice Example"
               })

      assert user.email == "alice@example.com"
      assert user.profile_id == profile.id
      assert profile.username == "alice"
      assert profile.name == "Alice Example"

      assert User.valid_password?(user, "verysecret123")
      refute User.valid_password?(user, "wrong")
    end

    test "rejects taken email" do
      {:ok, _} =
        Accounts.register(%{
          username: "alice",
          email: "alice@example.com",
          password: "verysecret123"
        })

      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.register(%{
                 username: "bob",
                 email: "alice@example.com",
                 password: "verysecret123"
               })

      assert "has already been taken" in errors_on(cs).email
    end

    test "rejects taken username" do
      {:ok, _} =
        Accounts.register(%{
          username: "alice",
          email: "alice@example.com",
          password: "verysecret123"
        })

      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.register(%{
                 username: "alice",
                 email: "alice2@example.com",
                 password: "verysecret123"
               })

      # Profile-side unique constraint message
      assert errors_on(cs).username
    end

    test "rejects too-short password" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.register(%{
                 username: "alice",
                 email: "alice@example.com",
                 password: "short"
               })

      assert errors_on(cs).password
    end
  end

  describe "get_by_email/1" do
    test "is case-insensitive (citext)" do
      {:ok, _} =
        Accounts.register(%{
          username: "alice",
          email: "Alice@Example.COM",
          password: "verysecret123"
        })

      assert %User{} = Accounts.get_by_email("alice@example.com")
      assert %User{} = Accounts.get_by_email("ALICE@EXAMPLE.COM")
    end

    test "returns nil for missing email" do
      assert is_nil(Accounts.get_by_email("nobody@example.com"))
    end
  end
end
