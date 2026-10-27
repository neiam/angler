defmodule Angler.Federation.InboxValidatorRetryTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Federation.{Activity, HTTPSignature}
  alias Angler.Federation.Workers.InboxValidator
  alias Angler.Profiles.Keypair

  @actor "http://remote.test/users/newcomer"

  setup do
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http_retry})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)

    {_pub, priv} = Keypair.generate()

    payload = %{
      "id" => @actor <> "/follows/1",
      "type" => "Follow",
      "actor" => @actor,
      "object" => "x"
    }

    body = Jason.encode!(payload)

    {:ok, headers} =
      HTTPSignature.sign(:post, "/f/inbox", "localhost", body, @actor <> "#main-key", priv, [
        {"Content-Type", "application/activity+json"}
      ])

    args = %{
      "headers" => Map.new(headers, fn {k, v} -> {String.downcase(k), v} end),
      "raw_body" => Base.encode64(body),
      "payload" => payload,
      "path" => "/f/inbox",
      "recipient_id" => nil
    }

    %{args: args}
  end

  defp actor_responds(status) do
    Req.Test.stub(:angler_http_retry, fn conn -> Plug.Conn.send_resp(conn, status, "") end)
  end

  test "an actor that is temporarily down is retried, not dropped", %{args: args} do
    actor_responds(503)

    assert {:error, {:actor_unavailable, {:unavailable, 503}}} =
             perform_job(InboxValidator, args, attempt: 1, max_attempts: 4)

    assert InboxValidator.backoff(%Oban.Job{attempt: 1}) == 180
    assert InboxValidator.backoff(%Oban.Job{attempt: 3}) == 3600
  end

  test "the last attempt records the rejection", %{args: args} do
    actor_responds(503)
    assert :ok = perform_job(InboxValidator, args, attempt: 4, max_attempts: 4)
    assert Repo.get_by(Activity, activity_id: @actor <> "/follows/1", status: :rejected)
  end

  test "an actor that is gone is dropped at once", %{args: args} do
    actor_responds(410)
    assert :ok = perform_job(InboxValidator, args, attempt: 1, max_attempts: 4)
    assert Repo.get_by(Activity, activity_id: @actor <> "/follows/1", status: :rejected)
  end
end
