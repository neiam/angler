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

  # Banned-domain behaviour is exercised end-to-end in BansTest (which has a
  # sandboxed DB). We don't need to repeat it here — this module is for the
  # DB-free guards (scheme + URL parsing).
end
