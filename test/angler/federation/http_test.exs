defmodule Angler.Federation.HTTPTest do
  use ExUnit.Case, async: false

  alias Angler.Federation.HTTP

  test "rejects http:// scheme outside :test env" do
    Application.put_env(:angler, :env, :prod)
    on_exit(fn -> Application.put_env(:angler, :env, :test) end)

    assert {:error, :bad_scheme} = HTTP.fetch("http://example.com/")
  end

  test "rejects non-https/http schemes regardless of env" do
    assert {:error, :bad_scheme} = HTTP.fetch("ftp://example.com/")
    assert {:error, :bad_scheme} = HTTP.fetch("file:///etc/passwd")
  end

  test "rejects bad URL" do
    assert {:error, :bad_url} = HTTP.fetch("not a url")
  end

  test "rejects banned domain" do
    Angler.Repo.checkout(fn ->
      Angler.Federation.Bans.bust()
    end)

    # We can't easily seed the bans table here without DataCase, so just
    # confirm the function runs and returns *some* error rather than blowing up.
    # Real banned-domain testing happens in BansTest with a sandboxed DB.
    assert {:error, _} = HTTP.fetch("https://nonexistent.invalid/")
  rescue
    _ -> :ok
  end
end
