defmodule Angler.Discover.BeagleTest do
  use ExUnit.Case, async: false

  alias Angler.Discover.Beagle

  setup do
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    Application.put_env(:angler, Angler.Discover.Beagle, enabled: false)

    on_exit(fn ->
      Application.delete_env(:angler, :req_options)
      Application.put_env(:angler, Angler.Discover.Beagle, enabled: false)
    end)

    Req.Test.set_req_test_to_shared(self())
    :ok
  end

  describe "enabled?/0" do
    test "defaults to false" do
      assert Beagle.enabled?() == false
    end

    test "true only when explicitly enabled" do
      Application.put_env(:angler, Angler.Discover.Beagle, enabled: true)
      assert Beagle.enabled?() == true
    end
  end

  describe "fetch_discover/0" do
    test "returns entries with usable ids, dropping the rest" do
      Req.Test.stub(:angler_http, fn conn ->
        body = %{
          "statuses" => [
            %{"id" => "https://pixelfed.social/p/a/1", "domain" => "pixelfed.social"},
            %{"id" => "", "domain" => "x"},
            %{"domain" => "no-id.example"}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:ok, [entry]} = Beagle.fetch_discover()
      assert entry["id"] == "https://pixelfed.social/p/a/1"
    end

    test "tolerates a payload without a statuses array" do
      Req.Test.stub(:angler_http, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"unexpected" => true}))
      end)

      assert {:ok, []} = Beagle.fetch_discover()
    end

    test "surfaces a non-200 as an error" do
      Req.Test.stub(:angler_http, fn conn ->
        Plug.Conn.send_resp(conn, 503, "down")
      end)

      assert {:error, {:bad_status, 503}} = Beagle.fetch_discover()
    end
  end
end
