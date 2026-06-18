defmodule Angler.TwoFactorTest do
  use Angler.DataCase, async: false

  alias Angler.Accounts
  alias Angler.Accounts.Secrets
  alias Angler.Accounts.TwoFactor

  defp user!(name \\ "alice") do
    {:ok, %{user: user}} =
      Accounts.register(%{
        username: name,
        email: "#{name}@example.com",
        password: "verysecret123",
        name: name
      })

    user
  end

  describe "Secrets" do
    test "round-trips a value" do
      blob = Secrets.encrypt("hunter2")
      assert {:ok, "hunter2"} = Secrets.decrypt(blob)
    end

    test "rejects a tampered blob" do
      <<a, rest::binary>> = Secrets.encrypt("hunter2")
      tampered = <<a + 1>> <> rest
      assert {:error, _} = Secrets.decrypt(tampered)
    end
  end

  describe "TOTP enable/verify" do
    test "enable with a valid code, then verify" do
      user = user!()
      secret = TwoFactor.new_secret()
      code = NimbleTOTP.verification_code(secret)

      assert {:ok, codes} = TwoFactor.enable(user, secret, code)
      assert length(codes) == 10

      reloaded = Accounts.get_user(user.id)
      assert TwoFactor.enabled?(reloaded)
      assert TwoFactor.verify_code(reloaded, NimbleTOTP.verification_code(secret)) == :ok
      assert TwoFactor.verify_code(reloaded, "000000") == {:error, :invalid_code}
    end

    test "enable rejects a bad code" do
      user = user!()
      secret = TwoFactor.new_secret()
      assert {:error, :invalid_code} = TwoFactor.enable(user, secret, "000000")
      refute TwoFactor.enabled?(Accounts.get_user(user.id))
    end

    test "disable clears the factor" do
      user = user!()
      secret = TwoFactor.new_secret()
      {:ok, _} = TwoFactor.enable(user, secret, NimbleTOTP.verification_code(secret))

      {:ok, _} = TwoFactor.disable(Accounts.get_user(user.id))
      refute TwoFactor.enabled?(Accounts.get_user(user.id))
    end
  end

  describe "recovery codes" do
    test "a code works once then is consumed" do
      user = user!()
      secret = TwoFactor.new_secret()
      {:ok, [code | _]} = TwoFactor.enable(user, secret, NimbleTOTP.verification_code(secret))

      reloaded = Accounts.get_user(user.id)
      assert TwoFactor.remaining_recovery_codes(reloaded) == 10
      assert TwoFactor.verify_recovery_code(reloaded, code) == :ok

      again = Accounts.get_user(user.id)
      assert TwoFactor.remaining_recovery_codes(again) == 9
      assert TwoFactor.verify_recovery_code(again, code) == {:error, :invalid_code}
    end

    test "regenerate replaces the set" do
      user = user!()
      secret = TwoFactor.new_secret()
      {:ok, original} = TwoFactor.enable(user, secret, NimbleTOTP.verification_code(secret))

      new_codes = TwoFactor.regenerate_recovery_codes!(Accounts.get_user(user.id))
      refute MapSet.equal?(MapSet.new(original), MapSet.new(new_codes))

      reloaded = Accounts.get_user(user.id)
      assert TwoFactor.verify_recovery_code(reloaded, hd(original)) == {:error, :invalid_code}
      assert TwoFactor.verify_recovery_code(Accounts.get_user(user.id), hd(new_codes)) == :ok
    end
  end
end
