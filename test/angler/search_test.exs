defmodule Angler.SearchTest do
  use Angler.DataCase, async: true

  alias Angler.Hashtags
  alias Angler.Profiles
  alias Angler.Search
  alias Angler.Statuses

  setup do
    {:ok, alpaca} = Profiles.create_profile(%{username: "alpaca"})
    {:ok, _bob} = Profiles.create_profile(%{username: "bob"})

    {:ok, status} =
      Statuses.create_remote(%{
        profile_id: alpaca.id,
        visibility: :public,
        caption: "alpacas are friendly creatures",
        rendered: "<p>alpacas are friendly creatures</p>",
        type: "text",
        local: false,
        uri: "http://remote.test/notes/alp"
      })

    Hashtags.ensure!("alpacas")
    Hashtags.ensure!("photography")

    %{alpaca: alpaca, status: status}
  end

  describe "accounts/2" do
    test "prefix-matches usernames", %{alpaca: alpaca} do
      assert [%{id: id}] = Search.accounts("alp")
      assert id == alpaca.id
    end

    test "blank query returns nothing" do
      assert Search.accounts("   ") == []
    end

    test "respects :limit" do
      assert Search.accounts("a", limit: 0) |> length() <= 1
    end
  end

  describe "hashtags/2" do
    test "prefix-matches names, ignoring a leading #" do
      assert [%{name: "alpacas"}] = Search.hashtags("#alp")
    end

    test "blank query returns nothing" do
      assert Search.hashtags("#") == []
    end
  end

  describe "statuses/3" do
    test "substring-matches captions", %{status: status} do
      assert [%{id: id}] = Search.statuses("friendly", nil)
      assert id == status.id
    end

    test "blank query returns nothing" do
      assert Search.statuses("", nil) == []
    end
  end

  describe "all/3" do
    test "returns all three buckets" do
      assert %{accounts: [_ | _], hashtags: [_ | _], statuses: [_ | _]} =
               Search.all("alp", nil)
    end
  end

  describe "clamp_limit/1" do
    test "bounds into [1, 40]" do
      assert Search.clamp_limit(0) == 1
      assert Search.clamp_limit(999) == 40
      assert Search.clamp_limit(20) == 20
    end
  end
end
