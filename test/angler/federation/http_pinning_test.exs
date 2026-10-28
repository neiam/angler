defmodule Angler.Federation.HTTPPinningTest do
  # DataCase: deliver/1 records host health in the DB.
  use Angler.DataCase, async: false

  alias Angler.Federation.HTTP
  alias Angler.Federation.HTTP.PinnedAdapter

  describe "with an injected resolver" do
    setup do
      test = self()

      put_resolver = fn answers ->
        Application.put_env(:angler, HTTP,
          resolver: fn host, family ->
            send(test, {:resolved, host, family})
            Map.get(answers, family, {:error, :nxdomain})
          end
        )
      end

      on_exit(fn -> Application.delete_env(:angler, HTTP) end)
      %{put_resolver: put_resolver}
    end

    test "connects to the checked address, not a second DNS answer", %{put_resolver: put} do
      # "localhost" really resolves to a listener on 127.0.0.1. The guard's
      # (injected) answer is public, so a client that re-resolved would land
      # on the listener; a pinned one goes to the public address instead.
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      put.(%{inet: {:ok, [{1, 1, 1, 1}]}})

      assert {:error, %Req.TransportError{}} =
               HTTP.deliver(
                 url: "http://localhost:#{port}/inbox",
                 body: "{}",
                 retry: false,
                 connect_options: [timeout: 300]
               )

      assert {:error, :timeout} = :gen_tcp.accept(listen, 100)
      assert_received {:resolved, ~c"localhost", :inet}
      refute_received {:resolved, _, _}
    end

    test "any private answer is refused", %{put_resolver: put} do
      put.(%{inet: {:ok, [{93, 184, 216, 34}, {10, 0, 0, 1}]}})
      assert {:error, :private_address} = HTTP.fetch("https://rebind.example/users/x")

      put.(%{inet6: {:ok, [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}]}})
      assert {:error, :private_address} = HTTP.fetch("https://rebind.example/users/x")

      put.(%{})
      assert {:error, :unresolvable} = HTTP.fetch("https://gone.example/users/x")
    end
  end

  describe "PinnedAdapter over TLS" do
    setup do
      key = [key: {:namedCurve, :secp256r1}, digest: :sha256]
      san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"fed.example"]}

      %{server_config: server, client_config: client} =
        :public_key.pkix_test_data(%{
          server_chain: %{root: key, intermediates: [], peer: key ++ [extensions: [san]]},
          client_chain: %{root: key, intermediates: [], peer: key}
        })

      {:ok, listen} =
        :ssl.listen(
          0,
          Keyword.merge(server,
            verify: :verify_none,
            fail_if_no_peer_cert: false,
            mode: :binary,
            ip: {127, 0, 0, 1},
            active: false,
            reuseaddr: true
          )
        )

      {:ok, {_, port}} = :ssl.sockname(listen)
      test = self()

      start_supervised!(
        {Task,
         fn ->
           Stream.repeatedly(fn -> serve(listen, test) end) |> Stream.run()
         end}
      )

      %{port: port, cacerts: Keyword.fetch!(client, :cacerts)}
    end

    defp serve(listen, test) do
      {:ok, socket} = :ssl.transport_accept(listen)

      case :ssl.handshake(socket, 5_000) do
        {:ok, socket} ->
          {:ok, info} = :ssl.connection_information(socket, [:sni_hostname])
          {:ok, request} = :ssl.recv(socket, 0, 5_000)
          send(test, {:served, info[:sni_hostname], request})

          :ssl.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
          )

          :ssl.close(socket)

        {:error, _} ->
          :ok
      end
    end

    defp pinned_get(url, hostname, cacerts) do
      Req.new(
        url: url,
        adapter: PinnedAdapter,
        retry: false,
        decode_body: false,
        connect_options: [transport_opts: [cacerts: cacerts]]
      )
      |> Req.Request.put_private(:angler_pin, {{127, 0, 0, 1}, hostname})
      |> Req.request()
    end

    test "uses the hostname for SNI, Host and certificate checks", %{port: port, cacerts: ca} do
      assert {:ok, %Req.Response{status: 200, body: "{}"}} =
               pinned_get("https://fed.example:#{port}/users/x", "fed.example", ca)

      assert_received {:served, ~c"fed.example", request}
      assert request =~ "GET /users/x HTTP/1.1"
      assert request =~ ~r/\r\nhost: fed\.example:#{port}\r\n/i
    end

    test "a certificate for another name is rejected", %{port: port, cacerts: ca} do
      assert {:error, %Req.TransportError{reason: {:tls_alert, {:bad_certificate, why}}}} =
               pinned_get("https://evil.example:#{port}/users/x", "evil.example", ca)

      assert to_string(why) =~ "hostname_check_failed"

      refute_received {:served, _, _}
    end
  end
end
