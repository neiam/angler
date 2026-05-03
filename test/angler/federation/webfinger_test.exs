defmodule Angler.Federation.WebfingerTest do
  use ExUnit.Case, async: true

  alias Angler.Federation.Webfinger
  alias Angler.Profiles.Profile

  @our "localhost"

  describe "parse_resource/2" do
    test "acct: with our domain → :local" do
      assert Webfinger.parse_resource("acct:alice@#{@our}", @our) == {:local, "alice"}
    end

    test "acct:domain@domain → :instance_actor" do
      assert Webfinger.parse_resource("acct:#{@our}@#{@our}", @our) == {:instance_actor, @our}
    end

    test "acct: with foreign domain → :invalid" do
      assert Webfinger.parse_resource("acct:alice@otherhost", @our) == :invalid
    end

    test "https URL with /users/ path → :local" do
      assert Webfinger.parse_resource("https://#{@our}/users/alice", @our) == {:local, "alice"}
    end

    test "https URL with /@ path → :local" do
      assert Webfinger.parse_resource("https://#{@our}/@alice", @our) == {:local, "alice"}
    end

    test "https URL with foreign host → :invalid" do
      assert Webfinger.parse_resource("https://otherhost/users/alice", @our) == :invalid
    end

    test "username with invalid chars → :invalid" do
      assert Webfinger.parse_resource("acct:alice/../bob@#{@our}", @our) == :invalid
    end

    test "overlong username → :invalid" do
      long = String.duplicate("a", 31)
      assert Webfinger.parse_resource("acct:#{long}@#{@our}", @our) == :invalid
    end

    test "empty / nil → :invalid" do
      assert Webfinger.parse_resource(nil, @our) == :invalid
      assert Webfinger.parse_resource("", @our) == :invalid
    end
  end

  describe "instance_actor_jrd/1" do
    test "subject + self link point at /i/actor" do
      jrd = Webfinger.instance_actor_jrd(@our)
      assert jrd["subject"] == "acct:#{@our}@#{@our}"

      self = Enum.find(jrd["links"], &(&1["rel"] == "self"))
      assert self["type"] == "application/activity+json"
      assert String.ends_with?(self["href"], "/i/actor")
    end
  end

  describe "profile_jrd/2" do
    test "shape" do
      profile = %Profile{username: "alice"}
      jrd = Webfinger.profile_jrd(profile, @our)

      assert jrd["subject"] == "acct:alice@#{@our}"

      self = Enum.find(jrd["links"], &(&1["rel"] == "self"))
      assert self["type"] == "application/activity+json"
      assert String.ends_with?(self["href"], "/users/alice")

      page = Enum.find(jrd["links"], &(&1["rel"] == "http://webfinger.net/rel/profile-page"))
      assert String.ends_with?(page["href"], "/@alice")
    end
  end
end
