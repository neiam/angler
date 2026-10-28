defmodule Angler.Federation.DeliveryHostsTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Ecto.Query

  alias Angler.Federation.{DeliveryHosts, HTTP, Instance}
  alias Angler.Federation.Workers.RelayDeliver

  defp instance(domain), do: Repo.one(from i in Instance, where: i.domain == ^domain)

  defp fail(domain, n), do: Enum.each(1..n, fn _ -> DeliveryHosts.record_failure(domain) end)

  describe "record_failure/1" do
    test "creates the instance row and backs off at the threshold" do
      fail("down.test", 4)
      assert %Instance{delivery_failures: 4, delivery_timeout: false} = instance("down.test")
      refute DeliveryHosts.unavailable?("down.test")

      fail("down.test", 1)
      inst = instance("down.test")
      assert inst.delivery_timeout
      assert DeliveryHosts.unavailable?("DOWN.test")

      # 1h at the threshold
      assert_in_delta DateTime.diff(inst.delivery_next_after, DateTime.utc_now()), 3600, 5
    end

    test "failures while backed off don't count; an expired backoff's probe doubles it" do
      fail("down.test", 7)
      assert %Instance{delivery_failures: 5} = instance("down.test")

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      Repo.update_all(from(i in Instance, where: i.domain == "down.test"),
        set: [delivery_next_after: past]
      )

      refute DeliveryHosts.unavailable?("down.test")
      fail("down.test", 1)
      inst = instance("down.test")
      assert inst.delivery_failures == 6
      assert_in_delta DateTime.diff(inst.delivery_next_after, DateTime.utc_now()), 7200, 5
    end
  end

  test "record_success/1 and reset/1 clear the host" do
    fail("down.test", 5)
    DeliveryHosts.record_success("down.test")

    assert %Instance{delivery_failures: 0, delivery_timeout: false, delivery_next_after: nil} =
             instance("down.test")

    fail("down.test", 5)
    assert DeliveryHosts.reset(" Down.Test ") == :ok
    refute DeliveryHosts.unavailable?("down.test")
  end

  test "backoff/1 doubles from an hour and caps at max_backoff" do
    assert DeliveryHosts.backoff(0) == 3600
    assert DeliveryHosts.backoff(3) == 28_800
    assert DeliveryHosts.backoff(8) == 604_800
    assert DeliveryHosts.backoff(1000) == 604_800
  end

  describe "through HTTP.deliver/1" do
    setup do
      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_delivery_hosts})
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)
    end

    defp stub_status(status) do
      Req.Test.stub(:angler_delivery_hosts, fn conn ->
        send(self(), :hit)
        Plug.Conn.send_resp(conn, status, "")
      end)
    end

    defp post, do: HTTP.deliver(url: "http://down.test/inbox", body: "{}", retry: false)

    test "5xx counts, 4xx leaves the count alone, 2xx clears" do
      stub_status(503)
      for _ <- 1..3, do: {:ok, %{status: 503}} = post()
      assert instance("down.test").delivery_failures == 3

      stub_status(401)
      {:ok, %{status: 401}} = post()
      assert instance("down.test").delivery_failures == 3

      stub_status(202)
      {:ok, %{status: 202}} = post()
      assert instance("down.test").delivery_failures == 0
    end

    test "a backed-off host is skipped without a request, and the worker cancels" do
      fail("down.test", 5)
      stub_status(202)

      assert {:error, :host_unavailable} = post()
      refute_received :hit

      assert {:cancel, :host_unavailable} =
               perform_job(RelayDeliver, %{
                 "verb" => "follow",
                 "inbox_url" => "http://down.test/inbox",
                 "follow_activity_id" => "http://angler.test/follows/1",
                 "object_url" => "https://www.w3.org/ns/activitystreams#Public"
               })

      refute_received :hit
    end
  end
end
