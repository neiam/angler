defmodule Angler.HashtagsTest do
  use Angler.DataCase, async: false

  alias Angler.Hashtags
  alias Angler.Hashtags.Hashtag

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
end
