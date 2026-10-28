defmodule Angler.Federation.HTTPTest do
  # DataCase: the redirect tests reach the banned-domain check, which reads the DB.
  use Angler.DataCase, async: false

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

  describe "private_ip?/1" do
    test "covers whole ranges, not just their first address" do
      for ip <- [
            {10, 1, 2, 3},
            {100, 64, 0, 1},
            {127, 0, 0, 2},
            {169, 254, 169, 254},
            {172, 31, 255, 255},
            {198, 18, 0, 1},
            {224, 0, 0, 1},
            {255, 255, 255, 255},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFC01, 0, 0, 0, 0, 0, 0, 1},
            {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
            {0xFE90, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1},
            # ::ffff:169.254.169.254 and 64:ff9b::10.0.0.1
            {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE},
            {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001}
          ] do
        assert HTTP.private_ip?(ip), "expected #{inspect(ip)} to be private"
      end
    end

    test "lets public addresses through" do
      for ip <- [
            {93, 184, 216, 34},
            {100, 128, 0, 1},
            {172, 32, 0, 1},
            {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}
          ] do
        refute HTTP.private_ip?(ip), "expected #{inspect(ip)} to be public"
      end
    end
  end

  describe "redirects" do
    setup do
      Application.put_env(:angler, :env, :prod)
      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http_redirect})

      on_exit(fn ->
        Application.put_env(:angler, :env, :test)
        Application.delete_env(:angler, :req_options)
      end)
    end

    test "each hop is re-checked, so a redirect can't reach a private address" do
      Req.Test.stub(:angler_http_redirect, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://169.254.169.254/latest/meta-data")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :private_address} = HTTP.fetch("https://93.184.216.34/users/x")
    end

    test "a public redirect is followed" do
      Req.Test.stub(:angler_http_redirect, fn
        %{request_path: "/old"} = conn ->
          conn |> Plug.Conn.put_resp_header("location", "/new") |> Plug.Conn.send_resp(301, "")

        conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(200, ~s({"id":"https://93.184.216.34/new"}))
      end)

      assert {:ok, %{"id" => "https://93.184.216.34/new"}} =
               HTTP.fetch("https://93.184.216.34/old")
    end

    test "redirect loops give up" do
      Req.Test.stub(:angler_http_redirect, fn conn ->
        conn |> Plug.Conn.put_resp_header("location", "/again") |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :too_many_redirects} = HTTP.fetch("https://93.184.216.34/again")
    end

    test "deliver refuses private inboxes and never follows redirects" do
      assert {:error, :private_address} =
               HTTP.deliver(url: "https://10.0.0.5/inbox", body: "{}", retry: false)

      Req.Test.stub(:angler_http_redirect, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://10.0.0.5/")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert {:ok, %{status: 307}} =
               HTTP.deliver(url: "https://93.184.216.34/inbox", body: "{}", retry: false)
    end

    test "download returns raw bytes of any type, under the guards and the cap" do
      Req.Test.stub(:angler_http_redirect, fn
        %{request_path: "/private"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://10.0.0.5/x.jpg")
          |> Plug.Conn.send_resp(302, "")

        conn ->
          conn |> Plug.Conn.put_resp_content_type("image/jpeg") |> Plug.Conn.send_resp(200, "abc")
      end)

      assert {:ok, "abc"} = HTTP.download("https://93.184.216.34/x.jpg", max_bytes: 3)
      assert {:error, :too_large} = HTTP.download("https://93.184.216.34/x.jpg", max_bytes: 2)

      assert {:error, :private_address} =
               HTTP.download("https://93.184.216.34/private", max_bytes: 10)
    end
  end

  # Banned-domain behaviour is exercised end-to-end in BansTest (which has a
  # sandboxed DB). We don't need to repeat it here — this module is for the
  # DB-free guards (scheme + URL parsing).
end
