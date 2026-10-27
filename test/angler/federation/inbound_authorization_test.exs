defmodule Angler.Federation.InboundAuthorizationTest do
  @moduledoc """
  Inbound activities may only act on what their (signature-verified) actor
  owns. Each test here is a forgery that used to succeed.
  """

  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.Federation.{Actor, HttpSignatureKey}
  alias Angler.Federation.Workers.DeleteWorker
  alias Angler.Follows.Follower
  alias Angler.Likes
  alias Angler.Likes.Federation, as: LikesFed
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Reblogs.Federation, as: ReblogsFed
  alias Angler.Statuses
  alias Angler.Statuses.Federation, as: StatusesFed

  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    {:ok, %{profile: alice}} =
      Accounts.register(%{username: "alice", email: "alice@example.com", password: "passwordOK1"})

    %{alice: alice, bob: remote!("bob", "remote.test"), mallory: remote!("mallory", "evil.test")}
  end

  defp remote!(username, host) do
    {:ok, p} =
      Profiles.create_profile(%{
        username: username,
        domain: host,
        remote_url: "http://#{host}/users/#{username}",
        inbox_url: "http://#{host}/users/#{username}/inbox",
        public_key_pem: "stub"
      })

    p
  end

  defp key!(key_id, owner_url, pem \\ "pem") do
    %HttpSignatureKey{}
    |> HttpSignatureKey.changeset(%{
      key_id: key_id,
      owner_url: owner_url,
      public_key_pem: pem,
      fetched_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp create(actor, object) do
    %{
      "type" => "Create",
      "id" => object["id"] <> "/activity",
      "actor" => actor,
      "object" => object
    }
  end

  defp note(id, author, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "Note",
        "id" => id,
        "attributedTo" => author,
        "content" => "<p>original</p>",
        "to" => [@public],
        "cc" => []
      },
      extra
    )
  end

  defp bob_note!(ctx, id \\ "http://remote.test/notes/1") do
    :ok =
      StatusesFed.handle_create(
        create(ctx.bob.remote_url, note(id, ctx.bob.remote_url)),
        ctx.bob.remote_url
      )

    Statuses.get_by_uri(id)
  end

  defp local_status!(profile, visibility) do
    {:ok, status} =
      Statuses.create_local(profile, %{"status" => "mine", "visibility" => visibility},
        broadcast: false
      )

    status
  end

  describe "signature key ↔ actor binding" do
    test "a key only verifies for the actor that owns it", ctx do
      key!("http://evil.test/users/mallory#main-key", ctx.mallory.remote_url)

      assert {:ok, "pem"} =
               Actor.public_key_for(
                 "http://evil.test/users/mallory#main-key",
                 ctx.mallory.remote_url
               )

      assert {:error, :key_actor_mismatch} =
               Actor.public_key_for("http://evil.test/users/mallory#main-key", ctx.bob.remote_url)
    end

    test "an uncached key id that isn't the actor's own is refused without fetching", ctx do
      assert {:error, :key_actor_mismatch} =
               Actor.public_key_for("http://evil.test/users/mallory#main-key", ctx.bob.remote_url)
    end

    test "an actor doc can't take over another actor's key id", ctx do
      key!("http://remote.test/users/bob#main-key", ctx.bob.remote_url, "bob-pem")

      Req.Test.stub(:angler_http, fn conn ->
        Req.Test.json(conn, %{
          "id" => "http://evil.test/users/eve",
          "type" => "Person",
          "preferredUsername" => "eve",
          "inbox" => "http://evil.test/users/eve/inbox",
          "publicKey" => %{
            "id" => "http://remote.test/users/bob#main-key",
            "owner" => "http://evil.test/users/eve",
            "publicKeyPem" => "eve-pem"
          }
        })
      end)

      Application.put_env(:angler, :req_options, plug: {Req.Test, :angler_http})
      on_exit(fn -> Application.delete_env(:angler, :req_options) end)

      _ = Actor.resolve("http://evil.test/users/eve")

      assert %HttpSignatureKey{
               public_key_pem: "bob-pem",
               owner_url: "http://remote.test/users/bob"
             } =
               Repo.get_by(HttpSignatureKey, key_id: "http://remote.test/users/bob#main-key")
    end
  end

  describe "Create" do
    test "rejects an object attributed to someone else", ctx do
      id = "http://evil.test/notes/1"

      assert {:error, :not_authored_by_actor} =
               StatusesFed.handle_create(
                 create(ctx.mallory.remote_url, note(id, ctx.bob.remote_url)),
                 ctx.mallory.remote_url
               )

      refute Statuses.get_by_uri(id)
    end

    test "rejects an object id on another host", ctx do
      id = "http://remote.test/notes/squat"

      assert {:error, :not_authored_by_actor} =
               StatusesFed.handle_create(
                 create(ctx.mallory.remote_url, note(id, ctx.mallory.remote_url)),
                 ctx.mallory.remote_url
               )

      refute Statuses.get_by_uri(id)
    end
  end

  describe "Update" do
    test "a non-owner can't rewrite a remote status", ctx do
      status = bob_note!(ctx)

      update = %{
        "type" => "Update",
        "object" => note(status.uri, ctx.bob.remote_url, %{"content" => "<p>pwned</p>"})
      }

      assert {:error, :not_owner} = StatusesFed.handle_update(update, ctx.mallory.remote_url)
      assert Statuses.get_by_uri(status.uri).rendered == "<p>original</p>"
    end

    test "nobody remote can rewrite a local status", ctx do
      status = local_status!(ctx.alice, "public")

      update = %{
        "type" => "Update",
        "object" => note(status.uri, ctx.alice.remote_url, %{"content" => "<p>pwned</p>"})
      }

      assert {:error, :not_owner} = StatusesFed.handle_update(update, ctx.mallory.remote_url)
      assert Statuses.get(status.id).caption == "mine"
    end

    test "the owner still can", ctx do
      status = bob_note!(ctx)

      update = %{
        "type" => "Update",
        "object" => note(status.uri, ctx.bob.remote_url, %{"content" => "<p>edited</p>"})
      }

      assert :ok = StatusesFed.handle_update(update, ctx.bob.remote_url)
      assert Statuses.get_by_uri(status.uri).rendered == "<p>edited</p>"
    end
  end

  describe "Delete" do
    defp delete!(actor, object),
      do:
        perform_job(DeleteWorker, %{
          "activity" => %{"type" => "Delete", "actor" => actor, "object" => object}
        })

    test "a remote actor can't delete a local status", ctx do
      status = local_status!(ctx.alice, "public")

      delete!(ctx.mallory.remote_url, status.uri)
      delete!(ctx.mallory.remote_url, %{"type" => "Tombstone", "id" => status.uri})

      assert Statuses.get(status.id).deleted_at == nil
    end

    test "a non-owner can't delete a remote status", ctx do
      status = bob_note!(ctx)
      delete!(ctx.mallory.remote_url, %{"type" => "Tombstone", "id" => status.uri})
      assert Statuses.get_by_uri(status.uri)
    end

    test "the owner can", ctx do
      status = bob_note!(ctx)
      delete!(ctx.bob.remote_url, %{"type" => "Tombstone", "id" => status.uri})
      refute Statuses.get_by_uri(status.uri)
    end

    test "Delete Person only deletes the sender itself", ctx do
      delete!(ctx.mallory.remote_url, %{"type" => "Person", "id" => ctx.bob.remote_url})
      assert Repo.get!(Profile, ctx.bob.id).status == nil

      delete!(ctx.bob.remote_url, %{"type" => "Person", "id" => ctx.bob.remote_url})
      assert Repo.get!(Profile, ctx.bob.id).status == "deleted"
    end

    test "Mastodon's bare-URL account Delete removes the account", ctx do
      delete!(ctx.bob.remote_url, ctx.bob.remote_url)
      assert Repo.get!(Profile, ctx.bob.id).status == "deleted"
    end
  end

  describe "Like / Announce visibility" do
    defp like(actor, status, n),
      do: LikesFed.handle_like(%{"id" => "#{actor}/likes/#{n}", "object" => status.uri}, actor)

    test "followers-only posts take likes from followers only", ctx do
      status = local_status!(ctx.alice, "private")
      assert {:error, :forbidden} = like(ctx.bob.remote_url, status, 1)

      %Follower{}
      |> Follower.changeset(%{
        profile_id: ctx.alice.id,
        following_id: ctx.bob.id,
        accepted_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      assert :ok = like(ctx.bob.remote_url, status, 2)
    end

    test "direct posts take no likes", ctx do
      status = local_status!(ctx.alice, "direct")
      assert {:error, :forbidden} = like(ctx.bob.remote_url, status, 1)
    end

    test "followers-only posts can't be boosted", ctx do
      status = local_status!(ctx.alice, "private")

      assert {:error, :forbidden} =
               ReblogsFed.handle_announce(
                 %{"id" => "http://remote.test/a/1", "object" => status.uri},
                 ctx.bob.remote_url
               )
    end

    test "only the liker can undo a like", ctx do
      status = local_status!(ctx.alice, "public")
      :ok = like(ctx.bob.remote_url, status, 1)
      undo = %{"object" => %{"type" => "Like", "id" => "#{ctx.bob.remote_url}/likes/1"}}

      :ok = LikesFed.handle_undo_like(undo, ctx.mallory.remote_url)
      assert Likes.get_by_remote_url("#{ctx.bob.remote_url}/likes/1")

      :ok = LikesFed.handle_undo_like(undo, ctx.bob.remote_url)
      refute Likes.get_by_remote_url("#{ctx.bob.remote_url}/likes/1")
    end
  end
end
