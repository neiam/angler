defmodule AnglerWeb.Federation.InstanceActorController do
  @moduledoc """
  /i/actor, /i/actor/inbox, /i/actor/outbox.

  See:
  * `plans/federation/endpoints/get_instance_actor.md`
  * `plans/federation/endpoints/post_instance_actor_inbox.md`
  * `plans/federation/endpoints/get_instance_actor_outbox.md`
  """

  use AnglerWeb, :controller

  alias Angler.Federation.InstanceActor

  def show(conn, _params) do
    actor = InstanceActor.ensure!() |> InstanceActor.to_actor()

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, Jason.encode_to_iodata!(actor))
  end

  def inbox(conn, _params) do
    # The endpoint exists for federation peers that discover it. We accept and
    # discard. Body is intentionally not parsed beyond Plug's read limit.
    case Plug.Conn.read_body(conn, length: 1_048_576) do
      {:ok, _body, conn} -> send_resp(conn, 202, "")
      {:more, _, conn} -> send_resp(conn, 413, "")
      {:error, _} -> send_resp(conn, 400, "")
    end
  end

  def outbox(conn, _params) do
    body = InstanceActor.outbox()

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, Jason.encode_to_iodata!(body))
  end
end
