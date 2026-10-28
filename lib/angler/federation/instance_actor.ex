defmodule Angler.Federation.InstanceActor do
  @moduledoc """
  Singleton ActivityPub `Application` actor for the instance.

  Used to sign blind outbound fetches (resolving a remote actor before any
  local user has interacted with them) so we don't have to attribute that
  traffic to a specific user.

  An RSA-2048 keypair is generated on first call to `ensure!/0` and persisted
  in the `instance_actors` table.
  """

  use Ecto.Schema

  alias Angler.Repo

  schema "instance_actors" do
    field :public_key_pem, :string
    field :private_key_pem, :binary
    field :key_id, :string
    field :owner_url, :string
    field :inbox_url, :string
    field :outbox_url, :string
    field :preferred_username, :string
    field :name, :string
    field :summary, :string
    field :rotated_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the singleton instance actor row, creating it (and a fresh RSA keypair)
  if it doesn't exist.
  """
  @spec ensure!() :: %__MODULE__{}
  def ensure! do
    case Repo.one(__MODULE__) do
      nil -> create!()
      actor -> actor
    end
  end

  # Callers can race to create it (e.g. Beagle's parallel ingests on a fresh
  # instance): the loser's insert is a no-op and it reads the winner's row.

  defp create! do
    base = AnglerWeb.Endpoint.url()
    domain = URI.parse(base).host

    {public_pem, private_pem} = generate_keypair()

    owner = base <> "/i/actor"

    %__MODULE__{
      public_key_pem: public_pem,
      private_key_pem: private_pem,
      key_id: owner <> "#main-key",
      owner_url: owner,
      inbox_url: owner <> "/inbox",
      outbox_url: owner <> "/outbox",
      preferred_username: domain,
      name: domain,
      summary: "Internal actor."
    }
    |> Repo.insert!(on_conflict: :nothing, conflict_target: :key_id)

    Repo.one!(__MODULE__)
  end

  @doc """
  Render the actor as the JSON map to be returned at `GET /i/actor`.

  Bytes are stable for a given keypair, so the result is safe to cache forever
  in the `:instance_actor` Nebulex namespace once that's wired up.
  """
  @spec to_actor(%__MODULE__{}) :: map()
  def to_actor(%__MODULE__{} = actor) do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => actor.owner_url,
      "type" => "Application",
      "inbox" => actor.inbox_url,
      "outbox" => actor.outbox_url,
      "preferredUsername" => actor.preferred_username,
      "name" => actor.name,
      "summary" => actor.summary,
      "url" => AnglerWeb.Endpoint.url() <> "/site/kb/instance-actor",
      "manuallyApprovesFollowers" => true,
      "publicKey" => %{
        "id" => actor.key_id,
        "owner" => actor.owner_url,
        "publicKeyPem" => actor.public_key_pem
      }
    }
  end

  @doc "Render the (empty) outbox JSON for the instance actor."
  @spec outbox() :: map()
  def outbox do
    base = AnglerWeb.Endpoint.url()

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        %{
          "manuallyApprovesFollowers" => "as:manuallyApprovesFollowers",
          "toot" => "http://joinmastodon.org/ns#",
          "featured" => %{"@id" => "toot:featured", "@type" => "@id"},
          "featuredTags" => %{"@id" => "toot:featuredTags", "@type" => "@id"},
          "alsoKnownAs" => %{"@id" => "as:alsoKnownAs", "@type" => "@id"},
          "movedTo" => %{"@id" => "as:movedTo", "@type" => "@id"},
          "schema" => "http://schema.org#",
          "PropertyValue" => "schema:PropertyValue",
          "value" => "schema:value",
          "discoverable" => "toot:discoverable",
          "Device" => "toot:Device",
          "Ed25519Signature" => "toot:Ed25519Signature",
          "Ed25519Key" => "toot:Ed25519Key",
          "Curve25519Key" => "toot:Curve25519Key",
          "EncryptedMessage" => "toot:EncryptedMessage",
          "publicKeyBase64" => "toot:publicKeyBase64",
          "deviceId" => "toot:deviceId",
          "claim" => %{"@type" => "@id", "@id" => "toot:claim"},
          "fingerprintKey" => %{"@type" => "@id", "@id" => "toot:fingerprintKey"},
          "identityKey" => %{"@type" => "@id", "@id" => "toot:identityKey"},
          "devices" => %{"@type" => "@id", "@id" => "toot:devices"},
          "messageFranking" => "toot:messageFranking",
          "messageType" => "toot:messageType",
          "cipherText" => "toot:cipherText",
          "suspended" => "toot:suspended"
        }
      ],
      "id" => base <> "/i/actor/outbox",
      "type" => "OrderedCollection",
      "totalItems" => 0,
      "first" => base <> "/i/actor/outbox?page=true",
      # Verbatim Pixelfed quirk (missing `&` between params); see plans/federation/endpoints/get_instance_actor_outbox.md.
      "last" => base <> "/i/actor/outbox?min_id=0page=true"
    }
  end

  @doc false
  # Public so tests can hit it without going through the Repo.
  def generate_keypair do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _v, n, e, _d, _p, _q, _dmp1, _dmq1, _iqmp, _other} = private
    public = {:RSAPublicKey, n, e}

    private_pem =
      [:public_key.pem_entry_encode(:RSAPrivateKey, private)]
      |> :public_key.pem_encode()

    # SubjectPublicKeyInfo wrapping ("BEGIN PUBLIC KEY") is the format Mastodon
    # and other AP peers expect; PKCS#1 ("BEGIN RSA PUBLIC KEY") is rejected by
    # some implementations.
    public_pem =
      [:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)]
      |> :public_key.pem_encode()

    {public_pem, private_pem}
  end
end
