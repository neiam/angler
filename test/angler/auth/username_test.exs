defmodule Angler.Auth.UsernameTest do
  use ExUnit.Case, async: true

  alias Angler.Auth.Username

  describe "validate/1" do
    test "accepts simple alpha-numeric usernames" do
      assert Username.validate("alice") == :ok
      assert Username.validate("Bob42") == :ok
    end

    test "accepts one of -, _, . in the middle" do
      assert Username.validate("alice.b") == :ok
      assert Username.validate("alice_b") == :ok
      assert Username.validate("alice-b") == :ok
    end

    test "rejects more than one special character" do
      assert {:error, _} = Username.validate("a.b.c")
      assert {:error, _} = Username.validate("a_b-c")
    end

    test "rejects starting with a special character" do
      assert {:error, _} = Username.validate(".alice")
      assert {:error, _} = Username.validate("-alice")
      assert {:error, _} = Username.validate("_alice")
    end

    test "rejects ending with a special character" do
      assert {:error, _} = Username.validate("alice.")
      assert {:error, _} = Username.validate("alice-")
      assert {:error, _} = Username.validate("alice_")
    end

    test "rejects all-digits (must contain a letter)" do
      assert {:error, _} = Username.validate("12345")
    end

    test "rejects too short or too long" do
      assert {:error, _} = Username.validate("a")
      assert {:error, _} = Username.validate(String.duplicate("a", 31))
    end

    test "rejects code-extension endings" do
      assert {:error, _} = Username.validate("alice.php")
      assert {:error, _} = Username.validate("alice.js")
      assert {:error, _} = Username.validate("alice.css")
    end

    test "rejects restricted names" do
      assert {:error, _} = Username.validate("admin")
      assert {:error, _} = Username.validate("root")
      assert {:error, _} = Username.validate("api")
    end

    test "rejects non-strings" do
      assert {:error, _} = Username.validate(nil)
      assert {:error, _} = Username.validate(123)
    end
  end
end
