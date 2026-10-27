defmodule AnglerWeb.Federation.UserActorControllerTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Profiles

  setup do
    {:ok, alice} = Profiles.create_profile(%{username: "alice"})

    alice
    |> Ecto.Changeset.change(followers_count: 3, following_count: 2, statuses_count: 7)
    |> Angler.Repo.update!()

    :ok
  end

  test "the collections the actor doc advertises exist, with counts only", %{conn: conn} do
    actor = conn |> get(~p"/users/alice") |> json_response(200)

    for {key, count} <- [{"outbox", 7}, {"followers", 3}, {"following", 2}] do
      body = conn |> get(URI.parse(actor[key]).path) |> json_response(200)

      assert body["id"] == actor[key]
      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == count
      refute Map.has_key?(body, "orderedItems")
    end
  end

  test "404 for an unknown user", %{conn: conn} do
    assert conn |> get(~p"/users/nobody/followers") |> json_response(404)
  end
end
