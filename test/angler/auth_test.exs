defmodule Angler.AuthTest do
  use Angler.DataCase, async: false

  alias Angler.Auth
  alias Angler.Auth.AppRegister

  describe "issue_code/2" do
    test "creates a fresh row + returns 6-digit plaintext" do
      assert {:ok, code, %AppRegister{} = row} = Auth.issue_code("alice@example.com")
      assert Regex.match?(~r/^\d{6}$/, code)
      assert row.email == "alice@example.com"
      assert row.uses == 1
      refute row.verify_code_hash == code
      assert byte_size(row.verify_code_hash) == 32
    end

    test "downcases email" do
      assert {:ok, _, row} = Auth.issue_code("Alice@Example.COM")
      assert row.email == "alice@example.com"
    end

    test "re-issuing increments uses + replaces hash" do
      {:ok, _, first} = Auth.issue_code("alice@example.com")
      {:ok, _, second} = Auth.issue_code("alice@example.com")

      assert second.id == first.id
      assert second.uses == 2
      refute second.verify_code_hash == first.verify_code_hash
    end

    test "rejects further issues once uses exceeds the cap" do
      # First call inserts (uses=1); next 5 calls re-issue (uses 2..6).
      # Pixelfed's threshold is `uses > 5`, so the 7th call is the first rejected.
      Enum.each(1..6, fn _ -> Auth.issue_code("alice@example.com") end)
      assert {:error, :too_many_attempts} = Auth.issue_code("alice@example.com")
    end
  end

  describe "verify_code/2" do
    setup do
      {:ok, code, _} = Auth.issue_code("alice@example.com")
      %{code: code}
    end

    test "matches a freshly-issued code", %{code: code} do
      assert :ok = Auth.verify_code("alice@example.com", code)
    end

    test "is case-insensitive on email", %{code: code} do
      assert :ok = Auth.verify_code("ALICE@example.com", code)
    end

    test "rejects wrong code" do
      assert :error = Auth.verify_code("alice@example.com", "000000")
    end

    test "rejects unknown email" do
      assert :error = Auth.verify_code("nobody@example.com", "000000")
    end

    test "rejects expired (older than 24h)", %{code: code} do
      register = Repo.get_by(AppRegister, email: "alice@example.com")
      old = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      Repo.update_all(AppRegister, set: [inserted_at: old])

      assert :error = Auth.verify_code(register.email, code)
    end

    test "does not consume the code", %{code: code} do
      assert :ok = Auth.verify_code("alice@example.com", code)
      assert :ok = Auth.verify_code("alice@example.com", code)
    end
  end

  describe "consume!/1" do
    test "deletes the registration row" do
      {:ok, _, _} = Auth.issue_code("alice@example.com")
      assert :ok = Auth.consume!("alice@example.com")
      assert is_nil(Auth.get_register("alice@example.com"))
    end

    test "is idempotent" do
      assert :ok = Auth.consume!("nobody@example.com")
    end
  end
end
