defmodule Angler.SearchTest do
  use Angler.DataCase, async: true

  alias Angler.Hashtags
  alias Angler.Likes.Like
  alias Angler.Profiles
  alias Angler.Reblogs.Reblog
  alias Angler.Repo
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

    test "hides unlisted posts from anonymous viewers", %{alpaca: alpaca} do
      {:ok, unlisted} =
        Statuses.create_remote(%{
          profile_id: alpaca.id,
          visibility: :unlisted,
          caption: "quiet alpaca whisper",
          rendered: "<p>quiet alpaca whisper</p>",
          type: "text",
          local: false,
          uri: "http://remote.test/notes/unlisted"
        })

      assert Search.statuses("whisper", nil) == []

      # A logged-in viewer (any id) sees it.
      {:ok, viewer} = Profiles.create_profile(%{username: "viewer"})
      assert [%{id: id}] = Search.statuses("whisper", viewer.id)
      assert id == unlisted.id
    end

    test "viewer always sees their own non-public posts", %{alpaca: alpaca} do
      {:ok, private} =
        Statuses.create_remote(%{
          profile_id: alpaca.id,
          visibility: :private,
          caption: "secret alpaca diary",
          rendered: "<p>secret alpaca diary</p>",
          type: "text",
          local: false,
          uri: "http://remote.test/notes/private"
        })

      # Hidden from others (even logged-in) and from anonymous.
      {:ok, other} = Profiles.create_profile(%{username: "other"})
      assert Search.statuses("diary", nil) == []
      assert Search.statuses("diary", other.id) == []

      # Visible to the author.
      assert [%{id: id}] = Search.statuses("diary", alpaca.id)
      assert id == private.id
    end
  end

  describe "statuses/3 surfaces interacted-with posts" do
    setup %{alpaca: author} do
      # A followers-only post by someone else — not visible to a viewer via the
      # public/unlisted rule, so it only shows up through interaction.
      {:ok, hidden} =
        Statuses.create_remote(%{
          profile_id: author.id,
          visibility: :private,
          caption: "hidden lagoon at dawn",
          rendered: "<p>hidden lagoon at dawn</p>",
          type: "text",
          local: false,
          uri: "http://remote.test/notes/hidden-#{System.unique_integer([:positive])}"
        })

      {:ok, viewer} = Profiles.create_profile(%{username: "viewer"})

      # Baseline: invisible to the viewer until they interact.
      assert Search.statuses("lagoon", viewer.id) == []

      %{hidden: hidden, viewer: viewer}
    end

    test "a liked post is found", %{hidden: hidden, viewer: viewer} do
      Repo.insert!(Like.changeset(%{profile_id: viewer.id, status_id: hidden.id}))
      assert [%{id: id}] = Search.statuses("lagoon", viewer.id)
      assert id == hidden.id
    end

    test "a boosted post is found", %{hidden: hidden, viewer: viewer} do
      Repo.insert!(Reblog.changeset(%{profile_id: viewer.id, status_id: hidden.id}))
      assert [%{id: id}] = Search.statuses("lagoon", viewer.id)
      assert id == hidden.id
    end

    test "a commented-on post is found", %{hidden: hidden, viewer: viewer} do
      {:ok, _reply} =
        Statuses.create_remote(%{
          profile_id: viewer.id,
          visibility: :public,
          caption: "what a view",
          rendered: "<p>what a view</p>",
          type: "text",
          local: false,
          in_reply_to_id: hidden.id,
          uri: "http://remote.test/notes/reply-#{System.unique_integer([:positive])}"
        })

      assert [%{id: id}] = Search.statuses("lagoon", viewer.id)
      assert id == hidden.id
    end

    test "still hidden from anonymous viewers even with interaction", %{
      hidden: hidden,
      viewer: viewer
    } do
      Repo.insert!(Like.changeset(%{profile_id: viewer.id, status_id: hidden.id}))
      assert Search.statuses("lagoon", nil) == []
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
