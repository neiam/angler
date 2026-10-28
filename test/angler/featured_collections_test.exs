defmodule Angler.FeaturedCollectionsTest do
  @moduledoc "FEP-7aa9: FeatureRequests for local profiles, stamps and revocation."

  use AnglerWeb.ConnCase, async: false
  use Oban.Testing, repo: Angler.Repo

  import Phoenix.LiveViewTest

  alias Angler.Accounts
  alias Angler.Accounts.Settings
  alias Angler.FeaturedCollections
  alias Angler.FeaturedCollections.Authorization
  alias Angler.Federation.ActorBuilder
  alias Angler.Federation.Workers.ActivityHandler
  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Quotes.Workers.QuoteDeliver
  alias Angler.Repo

  @collection_url "http://remote.test/users/bob/collections/1"

  setup do
    Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
    on_exit(fn -> Application.delete_env(:angler, :req_options) end)

    {:ok, %{user: user, profile: alice}} =
      Accounts.register(%{username: "alice", email: "alice@example.com", password: "passwordOK1"})

    {:ok, bob} =
      Profiles.create_profile(%{
        username: "bob",
        domain: "remote.test",
        remote_url: "http://remote.test/users/bob",
        inbox_url: "http://remote.test/users/bob/inbox",
        public_key_pem: "stub"
      })

    serve_collection(%{})
    %{alice: alice, user: user, bob: bob}
  end

  defp serve_collection(overrides) do
    doc =
      Map.merge(
        %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => @collection_url,
          "type" => "FeaturedCollection",
          "attributedTo" => "http://remote.test/users/bob",
          "name" => "<b>Photographers</b>",
          "summary" => "People I like"
        },
        overrides
      )

    Req.Test.stub(:angler_http, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Plug.Conn.send_resp(200, Jason.encode!(doc))
    end)
  end

  defp request(ctx, extra) do
    Map.merge(
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://remote.test/requests/1",
        "type" => "FeatureRequest",
        "object" => Profiles.actor_url(ctx.alice),
        "instrument" => @collection_url
      },
      extra
    )
  end

  defp handle(ctx, extra \\ %{}) do
    perform_job(ActivityHandler, %{
      "payload" => request(ctx, extra),
      "actor_url" => ctx.bob.remote_url,
      "recipient_id" => ctx.alice.id
    })
  end

  defp answers do
    for job <- all_enqueued(worker: QuoteDeliver), do: job.args["activity"]
  end

  test "approved by default: the Accept's stamp is served", %{conn: conn} = ctx do
    :ok = handle(ctx)

    assert [%{"type" => "Accept", "result" => stamp_url} = accept] = answers()
    assert accept["object"] == "http://remote.test/requests/1"
    assert accept["to"] == ctx.bob.remote_url

    assert [%Authorization{collection_name: "Photographers"}] = Repo.all(Authorization)

    stamp = conn |> get(URI.parse(stamp_url).path) |> json_response(200)
    assert stamp["type"] == "FeatureAuthorization"
    assert stamp["interactingObject"] == @collection_url
    assert stamp["interactionTarget"] == Profiles.actor_url(ctx.alice)

    # Asking again reuses the stamp.
    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert Repo.aggregate(Authorization, :count) == 1
  end

  test "policy nobody, or followers for a non-follower, is a Reject", ctx do
    {:ok, _} = Settings.merge_account(ctx.user.id, %{"can_feature" => "followers"})
    :ok = handle(ctx)
    assert [%{"type" => "Reject"}] = answers()

    {:ok, :accepted, _} = Follows.insert_inbound_follow(ctx.alice.id, ctx.bob.id)
    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert Enum.any?(answers(), &(&1["type"] == "Accept"))

    {:ok, _} = Settings.merge_account(ctx.user.id, %{"can_feature" => "nobody"})

    :ok =
      handle(ctx, %{
        "id" => "http://remote.test/requests/3",
        "instrument" => @collection_url <> "x"
      })

    assert Repo.aggregate(Authorization, :count) == 1
  end

  test "a collection that isn't the sender's FeaturedCollection is a Reject", ctx do
    serve_collection(%{"attributedTo" => "http://remote.test/users/carol"})
    :ok = handle(ctx)

    serve_collection(%{"type" => "Collection"})
    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})

    assert [%{"type" => "Reject"}, %{"type" => "Reject"}] = answers()
    assert Repo.all(Authorization) == []
  end

  test "forged hosts, other actors and unknown targets get no answer", ctx do
    :ok = handle(ctx, %{"id" => "http://evil.test/requests/1"})
    :ok = handle(ctx, %{"instrument" => "http://evil.test/collections/1"})
    :ok = handle(ctx, %{"actor" => "http://remote.test/users/carol"})
    :ok = handle(ctx, %{"object" => AnglerWeb.Endpoint.url() <> "/users/nobody"})
    :ok = handle(ctx, %{"object" => "http://remote.test/users/bob"})
    assert answers() == []
  end

  test "revoking sends a Delete, 410s the stamp and refuses a repeat", %{conn: conn} = ctx do
    :ok = handle(ctx)
    [auth] = Repo.all(Authorization)

    :ok = FeaturedCollections.revoke(ctx.alice.id, auth.id)

    assert %{"type" => "Delete", "object" => %{"type" => "FeatureAuthorization"}} =
             Enum.find(answers(), &(&1["type"] == "Delete"))

    assert conn |> get(URI.parse(FeaturedCollections.stamp_url(auth)).path) |> json_response(410)

    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert Enum.count(answers(), &(&1["type"] == "Reject")) == 1

    # Changing the policy clears the deny-record.
    {:ok, _} = Settings.merge_account(ctx.user.id, %{"can_feature" => "followers"})
    assert Repo.all(Authorization) == []
  end

  test "blocking the owner or their domain revokes", ctx do
    :ok = handle(ctx)
    {:ok, _} = Profiles.BlocksMutes.block(ctx.alice, ctx.bob)
    assert [%Authorization{state: "revoked"}] = Repo.all(Authorization)

    Repo.delete_all(Authorization)
    :ok = Profiles.BlocksMutes.unblock(ctx.alice, ctx.bob)
    :ok = handle(ctx, %{"id" => "http://remote.test/requests/2"})
    assert [%Authorization{state: "approved"}] = Repo.all(Authorization)

    :ok = Profiles.DomainBlocks.block(ctx.alice, "Remote.test")
    assert [%Authorization{state: "revoked"}] = Repo.all(Authorization)
  end

  test "the actor advertises interactionPolicy.canFeature", ctx do
    person = ActorBuilder.person(ctx.alice)

    assert person["interactionPolicy"]["canFeature"]["automaticApproval"] == [
             "https://www.w3.org/ns/activitystreams#Public"
           ]

    assert Enum.any?(person["@context"], &(is_map(&1) and Map.has_key?(&1, "canFeature")))

    {:ok, _} = Settings.merge_account(ctx.user.id, %{"can_feature" => "nobody"})

    assert ActorBuilder.person(ctx.alice)["interactionPolicy"]["canFeature"] == %{
             "automaticApproval" => [Profiles.actor_url(ctx.alice)]
           }
  end

  test "the settings page lists collections and removes one", %{conn: conn} = ctx do
    :ok = handle(ctx)
    [auth] = Repo.all(Authorization)

    conn = Plug.Test.init_test_session(conn, %{user_id: ctx.user.id})
    {:ok, lv, _html} = live(conn, ~p"/settings/featured")
    assert has_element?(lv, "#featured-#{auth.id}")

    lv |> element("#remove-featured-#{auth.id}") |> render_click()

    refute has_element?(lv, "#featured-#{auth.id}")
    assert has_element?(lv, "#featured-collections-empty")
    assert %Authorization{state: "revoked"} = Repo.get(Authorization, auth.id)
  end
end
