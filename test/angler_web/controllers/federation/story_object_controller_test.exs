defmodule AnglerWeb.Federation.StoryObjectControllerTest do
  @moduledoc """
  Coverage for the AP story-object endpoint at `GET /stories/:username/:id`.
  Authorization is bearcap-token-based (capabilities — possession of the
  token implies authorization), distinct from OAuth.
  """

  use AnglerWeb.ConnCase, async: false

  alias Angler.Accounts
  alias Angler.Repo
  alias Angler.Stories
  alias Angler.Stories.Story

  @fixture Path.join([__DIR__, "..", "..", "..", "fixtures", "red.jpg"])

  setup do
    Application.put_env(:angler, :stories_enabled, true)
    on_exit(fn -> Application.delete_env(:angler, :stories_enabled) end)

    root = Path.join([System.tmp_dir!(), "ang-storyap-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    Application.put_env(:angler, :media_root, root)

    on_exit(fn ->
      Application.delete_env(:angler, :media_root)
      File.rm_rf!(root)
    end)

    {:ok, %{profile: alice}} =
      Accounts.register(%{
        username: "alice",
        email: "alice@example.com",
        password: "verysecret123"
      })

    {:ok, draft} = Stories.add(alice, upload_fixture())
    {:ok, story} = Stories.publish(alice, draft.id, %{})

    %{alice: alice, story: story}
  end

  defp upload_fixture do
    src = Path.join(System.tmp_dir!(), "story-#{System.unique_integer([:positive])}.jpg")
    File.cp!(@fixture, src)
    %Plug.Upload{path: src, filename: "red.jpg", content_type: "image/jpeg"}
  end

  defp accept_json(conn), do: put_req_header(conn, "accept", "application/activity+json")

  test "404 when stories disabled", ctx do
    Application.put_env(:angler, :stories_enabled, false)

    assert json_response(
             ctx.conn |> accept_json() |> get(~p"/stories/alice/#{ctx.story.id}"),
             404
           )
  end

  test "404 without bearer", ctx do
    assert json_response(
             ctx.conn |> accept_json() |> get(~p"/stories/alice/#{ctx.story.id}"),
             404
           )
  end

  test "404 with wrong bearer", ctx do
    assert json_response(
             ctx.conn
             |> accept_json()
             |> put_req_header("authorization", "Bearer not-the-token")
             |> get(~p"/stories/alice/#{ctx.story.id}"),
             404
           )
  end

  test "200 returns AP-shape JSON when bearcap matches", ctx do
    body =
      ctx.conn
      |> accept_json()
      |> put_req_header("authorization", "Bearer " <> ctx.story.bearcap_token)
      |> get(~p"/stories/alice/#{ctx.story.id}")
      |> json_response(200)

    assert body["@context"] == "https://www.w3.org/ns/activitystreams"
    assert body["type"] == "Story"
    # Upstream StoryVerb, which inbound `Stories.Federation` parses back.
    assert body["attributedTo"] =~ "/users/alice"
    assert is_integer(body["duration"])
    assert is_boolean(body["can_reply"]) and is_boolean(body["can_react"])
    assert {:ok, _, _} = DateTime.from_iso8601(body["expiresAt"])
    assert %{"type" => "Image", "mediaType" => "image/jpeg"} = body["attachment"]
  end

  test "404 when story has expired (older than 20 minute publish window)", ctx do
    ctx.story
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second))
    |> Repo.update!()

    assert json_response(
             ctx.conn
             |> accept_json()
             |> put_req_header("authorization", "Bearer " <> ctx.story.bearcap_token)
             |> get(~p"/stories/alice/#{ctx.story.id}"),
             404
           )
  end

  test "redirects browser GETs to the user profile", ctx do
    conn =
      ctx.conn
      |> put_req_header("accept", "text/html")
      |> get(~p"/stories/alice/#{ctx.story.id}")

    assert redirected_to(conn) == "/users/alice"
  end

  test "404 when bearcap_token is nil (story drafted, never published)", ctx do
    {:ok, draft} = Stories.add(ctx.alice, upload_fixture())
    # Force-clear the bearcap on the published draft
    Repo.get!(Story, draft.id)
    |> Ecto.Changeset.change(
      active: true,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )
    |> Repo.update!()

    assert json_response(
             ctx.conn
             |> accept_json()
             |> put_req_header("authorization", "Bearer anything")
             |> get(~p"/stories/alice/#{draft.id}"),
             404
           )
  end
end
