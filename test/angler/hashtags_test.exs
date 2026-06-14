defmodule Angler.HashtagsTest do
  # async: false — usage-count cache lives in global :persistent_term.
  use Angler.DataCase, async: false

  alias Angler.Accounts
  alias Angler.Hashtags
  alias Angler.Hashtags.Hashtag
  alias Angler.Statuses

  setup do
    Hashtags.clear_usage_counts_cache()
    :ok
  end

  test "ensure!/1 inserts a fresh hashtag" do
    tag = Hashtags.ensure!("photography")
    assert %Hashtag{name: "photography", slug: "photography"} = tag
  end

  test "ensure!/1 is case-insensitive and idempotent" do
    a = Hashtags.ensure!("Photography")
    b = Hashtags.ensure!("PHOTOGRAPHY")
    c = Hashtags.ensure!("photography")

    assert a.id == b.id
    assert b.id == c.id
    assert Repo.aggregate(Hashtag, :count) == 1
  end

  test "ensure!/1 stores names lowercased" do
    Hashtags.ensure!("FilmPhoto")
    assert Repo.get_by(Hashtag, name: "filmphoto")
  end

  describe "usage_count/1" do
    setup do
      {:ok, %{profile: alice}} =
        Accounts.register(%{
          username: "alice",
          email: "alice@example.com",
          password: "verysecret123"
        })

      %{alice: alice}
    end

    test "counts public posts that use the tag (case-insensitive)", %{alice: alice} do
      {:ok, _} = Statuses.create_local(alice, %{"status" => "first #burrito"})
      {:ok, _} = Statuses.create_local(alice, %{"status" => "second #burrito"})
      Hashtags.clear_usage_counts_cache()

      assert Hashtags.usage_count("burrito") == 2
      assert Hashtags.usage_count("#BURRITO") == 2
    end

    test "is 0 for a tag with no posts" do
      Hashtags.ensure!("lonely")
      Hashtags.clear_usage_counts_cache()
      assert Hashtags.usage_count("lonely") == 0
    end

    test "excludes private posts", %{alice: alice} do
      {:ok, _} =
        Statuses.create_local(alice, %{"status" => "secret #taco", "visibility" => "private"})

      Hashtags.clear_usage_counts_cache()
      assert Hashtags.usage_count("taco") == 0
    end

    test "serves a cached snapshot until the cache is cleared", %{alice: alice} do
      {:ok, _} = Statuses.create_local(alice, %{"status" => "one #nachos"})
      Hashtags.clear_usage_counts_cache()
      assert Hashtags.usage_count("nachos") == 1

      # A new post is not reflected while the snapshot is still cached...
      {:ok, _} = Statuses.create_local(alice, %{"status" => "two #nachos"})
      assert Hashtags.usage_count("nachos") == 1

      # ...until the cache is invalidated.
      Hashtags.clear_usage_counts_cache()
      assert Hashtags.usage_count("nachos") == 2
    end
  end
end
