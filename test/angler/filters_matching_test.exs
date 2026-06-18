defmodule Angler.FiltersMatchingTest do
  use Angler.DataCase, async: false

  alias Angler.Filters
  alias Angler.Filters.Matching
  alias Angler.Hashtags.Muting
  alias Angler.Profiles
  alias Angler.Statuses
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  defp local!(u) do
    {:ok, p} = Profiles.create_profile(%{username: u})
    p
  end

  defp post!(profile, text) do
    {:ok, s} = Statuses.create_local(profile, %{"status" => text}, broadcast: false)
    s
  end

  defp keyword_filter!(profile, word, action) do
    {:ok, _} =
      Filters.create(profile.id, %{
        "title" => "f-#{word}",
        "filter_action" => action,
        "contexts" => ["home", "public"],
        "keywords_attributes" => [%{"keyword" => word}]
      })
  end

  describe "actions_for/3 — keyword filters" do
    test "matches caption text and reports the action" do
      viewer = local!("viewer")
      author = local!("author")
      keyword_filter!(viewer, "spoiler", "warn")

      s = post!(author, "huge spoiler ahead")
      clean = post!(author, "nothing to see")

      actions = Matching.actions_for(viewer.id, [s, clean], "home")
      assert %{action: "warn"} = actions[s.id]
      refute Map.has_key?(actions, clean.id)
    end

    test "strongest action wins across filters" do
      viewer = local!("viewer")
      author = local!("author")
      keyword_filter!(viewer, "alpha", "blur")
      keyword_filter!(viewer, "beta", "hide")

      s = post!(author, "alpha and beta together")
      assert %{action: "hide"} = Matching.actions_for(viewer.id, [s], "home")[s.id]
    end

    test "context scoping excludes filters not covering the context" do
      viewer = local!("viewer")
      author = local!("author")
      keyword_filter!(viewer, "spoiler", "hide")

      s = post!(author, "a spoiler")
      # filter contexts are home/public; the account context shouldn't match
      assert Matching.actions_for(viewer.id, [s], "account") == %{}
    end

    test "nil viewer yields no matches" do
      author = local!("author")
      s = post!(author, "anything")
      assert Matching.actions_for(nil, [s], "home") == %{}
    end
  end

  describe "actions_for/3 — muted hashtags" do
    test "matches a muted tag carried by the status" do
      viewer = local!("viewer")
      author = local!("author")
      {:ok, _} = Muting.mute(viewer, "politics", "hide")

      s = post!(author, "today in #politics")
      clean = post!(author, "today in #puppies")

      actions = Matching.actions_for(viewer.id, [s, clean], "home")
      assert %{action: "hide"} = actions[s.id]
      refute Map.has_key?(actions, clean.id)
    end
  end

  describe "render_many/3 integration" do
    test "drops hide-action posts and stamps filtered on warn" do
      viewer = local!("viewer")
      author = local!("author")
      keyword_filter!(viewer, "hideme", "hide")
      keyword_filter!(viewer, "warnme", "warn")

      hidden = post!(author, "please hideme now")
      warned = post!(author, "please warnme now")
      clean = post!(author, "all good here")

      rendered = StatusJSON.render_many([hidden, warned, clean], viewer.id, context: "home")
      ids = Enum.map(rendered, & &1["id"])

      refute Integer.to_string(hidden.id) in ids
      assert Integer.to_string(warned.id) in ids
      assert Integer.to_string(clean.id) in ids

      warned_json = Enum.find(rendered, &(&1["id"] == Integer.to_string(warned.id)))
      assert [%{"filter" => %{"filter_action" => "warn"}}] = warned_json["filtered"]

      clean_json = Enum.find(rendered, &(&1["id"] == Integer.to_string(clean.id)))
      assert clean_json["filtered"] == []
    end

    test "single render never drops, only stamps" do
      viewer = local!("viewer")
      author = local!("author")
      keyword_filter!(viewer, "hideme", "hide")

      s = post!(author, "please hideme")
      rendered = StatusJSON.render(s, viewer.id, context: "home")
      assert [%{"filter" => %{"filter_action" => "hide"}}] = rendered["filtered"]
    end
  end
end
