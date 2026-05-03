defmodule Angler.Federation.AudienceTest do
  use Angler.DataCase, async: false

  alias Angler.Federation.Audience
  alias Angler.Profiles

  defp local_actor(username), do: AnglerWeb.Endpoint.url() <> "/users/" <> username

  test "addressed to as:Public only → :public_only with no targeted ids" do
    payload = %{"to" => ["https://www.w3.org/ns/activitystreams#Public"]}
    assert Audience.resolve(payload) == {:public_only, []}
  end

  test "addressed only to a known local actor URL → :targeted with their id" do
    {:ok, profile} = Profiles.create_profile(%{username: "alice"})

    payload = %{"to" => [local_actor("alice")]}

    assert {:targeted, [id]} = Audience.resolve(payload)
    assert id == profile.id
  end

  test "as:Public + a local follower URL → :public_only with the local id" do
    {:ok, profile} = Profiles.create_profile(%{username: "bob"})

    payload = %{
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [local_actor("bob")]
    }

    assert {:public_only, ids} = Audience.resolve(payload)
    assert profile.id in ids
  end

  test "foreign actor URLs are not local recipients" do
    payload = %{"to" => ["https://remote.test/users/eve"]}
    assert {:targeted, []} = Audience.resolve(payload)
  end

  test "no addressing → :targeted with empty list" do
    assert Audience.resolve(%{}) == {:targeted, []}
  end

  test "soft-deleted local profiles are not recipients" do
    {:ok, profile} = Profiles.create_profile(%{username: "carol"})

    profile
    |> Ecto.Changeset.change(status: "deleted")
    |> Repo.update!()

    payload = %{"to" => [local_actor("carol")]}
    assert {:targeted, []} = Audience.resolve(payload)
  end
end
