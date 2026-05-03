defmodule Angler.Federation.BansTest do
  use Angler.DataCase, async: false

  alias Angler.Federation.{Bans, Instance}

  setup do
    Bans.bust()
    on_exit(&Bans.bust/0)
    :ok
  end

  test "unbanned domain is not banned?" do
    refute Bans.banned?("mastodon.social")
  end

  test "banned domain is banned? after bust" do
    {:ok, _} =
      %{domain: "spammy.example"}
      |> Instance.upsert_changeset()
      |> Repo.insert()

    {1, _} =
      from(i in Instance, where: i.domain == "spammy.example")
      |> Repo.update_all(set: [banned: true])

    Bans.bust()

    assert Bans.banned?("spammy.example")
    assert Bans.banned?("SPAMMY.example")
    refute Bans.banned?("other.example")
  end
end
