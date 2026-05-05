defmodule AnglerWeb.MastodonAPI.LandingExploreTest do
  use AnglerWeb.ConnCase, async: false

  alias Angler.Profiles
  alias Angler.Statuses

  defp insert_photo!(profile, opts) do
    {:ok, s} =
      Statuses.create_remote(%{
        profile_id: profile.id,
        visibility: opts[:visibility] || :public,
        caption: opts[:caption] || "x",
        rendered: "<p>x</p>",
        type: opts[:type] || "photo",
        local: true,
        is_nsfw: opts[:nsfw] || false,
        uri: "http://remote.test/notes/#{System.unique_integer([:positive])}"
      })

    s
  end

  test "GET /api/v1.1/landing/v1/explore is anonymous and returns recent photos", %{conn: conn} do
    {:ok, alice} = Profiles.create_profile(%{username: "alice"})
    photo = insert_photo!(alice, caption: "scenic", type: "photo")

    body = conn |> get(~p"/api/v1.1/landing/v1/explore") |> json_response(200)

    assert is_list(body)
    assert Enum.any?(body, &(&1["id"] == Integer.to_string(photo.id)))
  end

  test "skips text-only and NSFW posts", %{conn: conn} do
    {:ok, alice} = Profiles.create_profile(%{username: "alice"})
    _ = insert_photo!(alice, type: "text", caption: "words")
    _ = insert_photo!(alice, nsfw: true, caption: "spicy")

    body = conn |> get(~p"/api/v1.1/landing/v1/explore") |> json_response(200)
    assert body == []
  end

  test "404 when explore is disabled", %{conn: conn} do
    Application.put_env(:angler, :landing_explore_enabled, false)
    on_exit(fn -> Application.delete_env(:angler, :landing_explore_enabled) end)

    assert json_response(get(conn, ~p"/api/v1.1/landing/v1/explore"), 404)
  end
end
