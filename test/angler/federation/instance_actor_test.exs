defmodule Angler.Federation.InstanceActorTest do
  use Angler.DataCase, async: false

  alias Angler.Federation.InstanceActor

  describe "ensure!/0" do
    test "creates the singleton on first call" do
      assert Repo.aggregate(InstanceActor, :count) == 0

      actor = InstanceActor.ensure!()

      assert Repo.aggregate(InstanceActor, :count) == 1
      assert actor.public_key_pem =~ "BEGIN PUBLIC KEY"
      assert actor.private_key_pem
      assert String.ends_with?(actor.owner_url, "/i/actor")
      assert String.ends_with?(actor.key_id, "#main-key")
    end

    test "is idempotent" do
      a = InstanceActor.ensure!()
      b = InstanceActor.ensure!()

      assert a.id == b.id
      assert Repo.aggregate(InstanceActor, :count) == 1
    end
  end

  describe "to_actor/1" do
    test "renders the AP JSON shape" do
      actor = InstanceActor.ensure!()
      json = InstanceActor.to_actor(actor)

      assert json["type"] == "Application"
      assert json["id"] == actor.owner_url
      assert json["inbox"] == actor.inbox_url
      assert json["outbox"] == actor.outbox_url
      assert json["publicKey"]["id"] == actor.key_id
      assert json["publicKey"]["owner"] == actor.owner_url
      assert json["publicKey"]["publicKeyPem"] == actor.public_key_pem

      assert "https://www.w3.org/ns/activitystreams" in json["@context"]
      assert "https://w3id.org/security/v1" in json["@context"]
    end
  end

  describe "outbox/0" do
    test "is an OrderedCollection with totalItems 0" do
      json = InstanceActor.outbox()

      assert json["type"] == "OrderedCollection"
      assert json["totalItems"] == 0
      assert String.ends_with?(json["id"], "/i/actor/outbox")
    end
  end

  describe "generate_keypair/0" do
    test "produces a parseable RSA pair" do
      {public_pem, private_pem} = InstanceActor.generate_keypair()

      [public_entry] = :public_key.pem_decode(public_pem)
      [private_entry] = :public_key.pem_decode(private_pem)

      assert elem(public_entry, 0) == :SubjectPublicKeyInfo
      assert elem(private_entry, 0) == :RSAPrivateKey

      # Decoded RSA modulus should round-trip — i.e., we can decode the public
      # entry, sign with the private, verify with the public.
      private = :public_key.pem_entry_decode(private_entry)
      public = :public_key.pem_entry_decode(public_entry)

      msg = "hello federation"
      sig = :public_key.sign(msg, :sha256, private)
      assert :public_key.verify(msg, :sha256, sig, public)
    end
  end
end
