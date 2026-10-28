defmodule AnglerWeb.Federation.InstanceActorController do
  @moduledoc """
  /i/actor and /i/actor/outbox. The inbox (`POST /i/actor/inbox`) is served by
  `AnglerWeb.Federation.InboxController.instance/2` so relay activities flow
  through the same verify→dispatch pipeline as the shared inbox. While we
  disclose blocks, the actor advertises our FEP-070c endpoint as
  `blockSynchronization`.

  See:
  * `plans/federation/endpoints/get_instance_actor.md`
  * `plans/federation/endpoints/get_instance_actor_outbox.md`
  """

  use AnglerWeb, :controller

  alias Angler.Federation.{BlockSync, InstanceActor}

  def show(conn, _params) do
    actor = InstanceActor.ensure!() |> InstanceActor.to_actor()

    actor =
      if BlockSync.disclosing?(), do: BlockSync.decorate_instance_actor(actor), else: actor

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, Jason.encode_to_iodata!(actor))
  end

  def outbox(conn, _params) do
    body = InstanceActor.outbox()

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, Jason.encode_to_iodata!(body))
  end
end
