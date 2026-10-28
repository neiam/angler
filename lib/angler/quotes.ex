defmodule Angler.Quotes do
  @moduledoc """
  FEP-044f consent-respecting quote posts, as upstream v0.15's QuoteService.

  Remote servers ask with a `QuoteRequest` before quoting a local post; the
  post's canQuote policy decides, and an approval is a `QuoteAuthorization`
  stamp (`Angler.Quotes.Authorization`) they attach to the quote. Only
  automatic approval exists: an audience the policy doesn't approve
  automatically is refused, there is no review queue.

  A post's policy is an audience bitmask in `statuses.quote_policy`: the low
  byte approved automatically, the high byte manually (only ever read off
  other servers' posts). `nil` means the author's account default
  (`can_quote` setting: `"everyone"`, `"followers"` or `"nobody"`); `0` is
  an explicit "nobody". Only public and unlisted posts are quotable at all.

  Stamps are revoked (a `Delete` of the stamp is sent to the quoter) when the
  author blocks the quoter or their domain, or deletes the post.
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts.{Settings, User}
  alias Angler.Follows
  alias Angler.Profiles
  alias Angler.Profiles.{Block, DomainBlock, Profile}
  alias Angler.Quotes.Authorization
  alias Angler.Quotes.Workers.QuoteDeliver
  alias Angler.Repo
  alias Angler.Statuses.Status

  @flag_public 1
  @flag_followers 2
  @flag_following 4
  @manual_shift 8

  @policies ~w(everyone followers nobody)
  @policy_flags %{"everyone" => @flag_public, "followers" => @flag_followers, "nobody" => 0}

  # Mastodon API `quote_approval_policy` values.
  @api_policies %{"public" => "everyone", "followers" => "followers", "nobody" => "nobody"}

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  @doc """
  JSON-LD terms for `interactionPolicy.canQuote`, merged into the @context
  of our Notes so they compact as on Mastodon and GoToSocial.
  """
  def note_context_terms do
    %{
      "gts" => "https://gotosocial.org/ns#",
      "interactionPolicy" => %{"@id" => "gts:interactionPolicy", "@type" => "@id"},
      "canQuote" => %{"@id" => "gts:canQuote", "@type" => "@id"},
      "automaticApproval" => %{"@id" => "gts:automaticApproval", "@type" => "@id"},
      "manualApproval" => %{"@id" => "gts:manualApproval", "@type" => "@id"}
    }
  end

  @stamp_context [
    "https://www.w3.org/ns/activitystreams",
    %{
      "gts" => "https://gotosocial.org/ns#",
      "QuoteAuthorization" => "https://w3id.org/fep/044f#QuoteAuthorization",
      "interactingObject" => %{"@id" => "gts:interactingObject", "@type" => "@id"},
      "interactionTarget" => %{"@id" => "gts:interactionTarget", "@type" => "@id"}
    }
  ]

  @request_context [
    "https://www.w3.org/ns/activitystreams",
    %{"QuoteRequest" => "https://w3id.org/fep/044f#QuoteRequest"}
  ]

  def policies, do: @policies

  ## Policy

  @doc "A local profile's account-wide canQuote default."
  @spec account_policy(Profile.t()) :: String.t()
  def account_policy(%Profile{domain: nil, id: pid}) do
    with %User{id: uid} <- Repo.get_by(User, profile_id: pid),
         p when p in @policies <- Settings.account_settings(uid)["can_quote"] do
      p
    else
      _ -> "everyone"
    end
  end

  def account_policy(_), do: "nobody"

  @doc "Can anyone quote this post at all (local, active, public or unlisted)?"
  @spec quotable?(Status.t()) :: boolean()
  def quotable?(%Status{} = status) do
    status = Repo.preload(status, :profile)

    status.local and is_nil(status.reblog_of_id) and is_nil(status.group_id) and
      is_nil(status.deleted_at) and status.visibility in [:public, :unlisted] and
      active?(status.profile)
  end

  defp active?(%Profile{domain: nil, status: nil, is_suspended: false}), do: true
  defp active?(_), do: false

  @doc "The effective audience bitmask for a post."
  @spec status_flags(Status.t()) :: non_neg_integer()
  def status_flags(%Status{} = status) do
    status = Repo.preload(status, :profile)

    cond do
      not quotable?(status) -> 0
      is_integer(status.quote_policy) -> Bitwise.band(status.quote_policy, 0xFFFF)
      true -> Map.fetch!(@policy_flags, account_policy(status.profile))
    end
  end

  @doc "The closest named policy for a bitmask, by who's approved automatically."
  @spec from_flags(non_neg_integer()) :: String.t()
  def from_flags(flags) do
    automatic = automatic(flags)

    cond do
      Bitwise.band(automatic, @flag_public) != 0 -> "everyone"
      Bitwise.band(automatic, @flag_followers) != 0 -> "followers"
      true -> "nobody"
    end
  end

  @doc """
  A Mastodon `quote_approval_policy` as the bitmask to store: `{:ok, nil}`
  clears the override, anything unknown is `:error`.
  """
  @spec from_api_policy(term()) :: {:ok, non_neg_integer() | nil} | :error
  def from_api_policy(nil), do: {:ok, nil}

  def from_api_policy(value) when is_map_key(@api_policies, value),
    do: {:ok, Map.fetch!(@policy_flags, Map.fetch!(@api_policies, value))}

  def from_api_policy(_), do: :error

  @doc "The Mastodon `quote_approval_policy` for a post."
  @spec api_policy(Status.t()) :: String.t()
  def api_policy(%Status{} = status) do
    named = status |> status_flags() |> from_flags()
    Enum.find_value(@api_policies, "nobody", fn {api, ours} -> if ours == named, do: api end)
  end

  @doc """
  The Mastodon `source[quote_policy]` / our `can_quote` setting from either
  spelling, or nil.
  """
  @spec account_policy_param(term()) :: String.t() | nil
  def account_policy_param(p) when p in @policies, do: p
  def account_policy_param(p) when is_map_key(@api_policies, p), do: Map.fetch!(@api_policies, p)
  def account_policy_param(_), do: nil

  defp automatic(flags), do: Bitwise.band(flags, 0xFF)
  defp manual(flags), do: flags |> Bitwise.bsr(@manual_shift) |> Bitwise.band(0xFF)

  @doc """
  The Note's `interactionPolicy`. Nobody is expressed as the author's own
  id, since an empty list is the same as a missing property in JSON-LD.
  """
  @spec interaction_policy(Status.t(), Profile.t()) :: map()
  def interaction_policy(%Status{} = status, %Profile{} = author) do
    flags = status_flags(%{status | profile: author})
    actor_url = Profiles.actor_url(author)

    automatic =
      case audience_uris(automatic(flags), actor_url) do
        [] -> [actor_url]
        uris -> uris
      end

    can_quote =
      case audience_uris(manual(flags), actor_url) do
        [] -> %{"automaticApproval" => automatic}
        manual -> %{"automaticApproval" => automatic, "manualApproval" => manual}
      end

    %{"canQuote" => can_quote}
  end

  defp audience_uris(flags, actor_url) do
    [
      {@flag_public, @as_public},
      {@flag_followers, actor_url <> "/followers"},
      {@flag_following, actor_url <> "/following"}
    ]
    |> Enum.filter(fn {flag, _} -> Bitwise.band(flags, flag) != 0 end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  May remote `actor` quote `status`? Policy, blocks and domain blocks; a
  revoked stamp for the same quote post is the caller's to check.
  """
  @spec can_quote?(Status.t(), Profile.t()) :: boolean()
  def can_quote?(%Status{} = status, %Profile{} = actor) do
    automatic = automatic(status_flags(status))
    author_id = status.profile_id

    cond do
      not quotable?(status) or is_nil(actor.domain) or not is_nil(actor.status) -> false
      blocked?(author_id, actor) -> false
      Bitwise.band(automatic, @flag_public) != 0 -> true
      Bitwise.band(automatic, @flag_followers) != 0 and follows?(actor.id, author_id) -> true
      Bitwise.band(automatic, @flag_following) != 0 and follows?(author_id, actor.id) -> true
      true -> false
    end
  end

  defp blocked?(author_id, %Profile{id: aid, domain: domain}) do
    Repo.exists?(from b in Block, where: b.profile_id == ^author_id and b.target_id == ^aid) or
      Repo.exists?(
        from d in DomainBlock,
          where: d.profile_id == ^author_id and d.domain == ^String.downcase(domain)
      )
  end

  defp follows?(follower_id, followee_id),
    do: match?(%{accepted_at: %DateTime{}}, Follows.get_follower(followee_id, follower_id))

  ## Stamps

  @spec find(integer(), String.t()) :: Authorization.t() | nil
  def find(status_id, quote_url),
    do: Repo.get_by(Authorization, status_id: status_id, quote_url: quote_url)

  @doc "Issue (or reuse) the stamp for a quote post."
  @spec authorize(Status.t(), Profile.t(), String.t(), String.t() | nil) :: Authorization.t()
  def authorize(%Status{} = status, %Profile{} = actor, quote_url, request_url) do
    %Authorization{
      id: Angler.Snowflake.next(),
      profile_id: status.profile_id,
      status_id: status.id,
      actor_id: actor.id,
      quote_url: quote_url,
      request_url: request_url
    }
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:status_id, :quote_url])

    find(status.id, quote_url)
  end

  @doc "A profile's approved stamps, newest first, for the settings page."
  @spec list_approved(integer(), pos_integer()) :: [Authorization.t()]
  def list_approved(profile_id, limit \\ 50) do
    Repo.all(
      from a in Authorization,
        where: a.profile_id == ^profile_id and a.state == "approved",
        order_by: [desc: a.id],
        limit: ^limit,
        preload: [:actor, :status]
    )
  end

  @doc """
  Withdraw consent: the row stays, revoked (the stamp URL then serves 410
  and a repeat request is refused), and the quoter gets a `Delete`.
  """
  @spec revoke(Authorization.t()) :: :ok
  def revoke(%Authorization{state: "revoked"}), do: :ok

  def revoke(%Authorization{} = auth) do
    auth = Repo.preload(auth, [:profile, :actor, :status])
    activity = delete_activity(auth)

    auth
    |> Ecto.Changeset.change(state: "revoked", revoked_at: DateTime.utc_now())
    |> Repo.update!()

    QuoteDeliver.enqueue(auth.profile_id, auth.actor_id, activity)
    :ok
  end

  @doc "Revoke one of `profile_id`'s stamps by id. `:not_found` if it isn't theirs."
  @spec revoke(integer(), integer()) :: :ok | :not_found
  def revoke(profile_id, id) do
    case Repo.get_by(Authorization, id: id, profile_id: profile_id) do
      nil -> :not_found
      auth -> revoke(auth)
    end
  end

  @doc "Revoke every stamp `profile_id` gave `actor_id` (they blocked them)."
  @spec revoke_for_actor(integer(), integer()) :: :ok
  def revoke_for_actor(profile_id, actor_id) do
    from(a in Authorization,
      where: a.profile_id == ^profile_id and a.actor_id == ^actor_id and a.state == "approved"
    )
    |> Repo.all()
    |> Enum.each(&revoke/1)
  end

  @doc "Revoke every stamp `profile_id` gave anyone on `domain`."
  @spec revoke_for_domain(integer(), String.t()) :: :ok
  def revoke_for_domain(profile_id, domain) do
    domain = String.downcase(domain)

    from(a in Authorization,
      join: p in Profile,
      on: p.id == a.actor_id,
      where: a.profile_id == ^profile_id and a.state == "approved" and p.domain == ^domain
    )
    |> Repo.all()
    |> Enum.each(&revoke/1)
  end

  @doc """
  The quoted post is being deleted: tell every approved quoter (they may not
  follow the author, so miss the post's own Delete), then drop the rows.
  """
  @spec status_deleted(integer()) :: :ok
  def status_deleted(status_id) do
    from(a in Authorization, where: a.status_id == ^status_id and a.state == "approved")
    |> Repo.all()
    |> Enum.each(&revoke/1)

    {_, _} = Repo.delete_all(from a in Authorization, where: a.status_id == ^status_id)
    :ok
  end

  @doc """
  The quoter deleted their quote post: its stamp goes too. Revoked rows are
  kept, or deleting a quote would wipe its deny-record.
  """
  @spec forget_quote(String.t(), String.t()) :: :ok
  def forget_quote(actor_url, quote_url) do
    {_, _} =
      from(a in Authorization,
        join: p in Profile,
        on: p.id == a.actor_id,
        where: a.quote_url == ^quote_url and a.state == "approved" and p.remote_url == ^actor_url
      )
      |> Repo.delete_all()

    :ok
  end

  @doc "A remote account is gone: so are the stamps it held."
  @spec actor_deleted(integer()) :: :ok
  def actor_deleted(actor_id) do
    {_, _} = Repo.delete_all(from a in Authorization, where: a.actor_id == ^actor_id)
    :ok
  end

  ## Activities

  @spec stamp_url(Authorization.t()) :: String.t()
  def stamp_url(%Authorization{} = auth) do
    auth = Repo.preload(auth, :profile)
    Profiles.actor_url(auth.profile) <> "/quote_authorizations/" <> Integer.to_string(auth.id)
  end

  @doc "The stamp object: references only, per the FEP."
  @spec stamp_object(Authorization.t()) :: map()
  def stamp_object(%Authorization{} = auth) do
    auth = Repo.preload(auth, [:profile, :status])

    %{
      "@context" => @stamp_context,
      "id" => stamp_url(auth),
      "type" => "QuoteAuthorization",
      "attributedTo" => Profiles.actor_url(auth.profile),
      "interactingObject" => auth.quote_url,
      "interactionTarget" => status_url(auth.status)
    }
  end

  @spec accept_activity(Authorization.t(), Profile.t(), String.t()) :: map()
  def accept_activity(%Authorization{} = auth, %Profile{} = requester, request_url) do
    auth = Repo.preload(auth, [:profile, :status])
    author_url = Profiles.actor_url(auth.profile)

    %{
      "@context" => @request_context,
      "id" => author_url <> "#accepts/quotes/" <> Integer.to_string(auth.id),
      "type" => "Accept",
      "actor" => author_url,
      "to" => Profiles.actor_url(requester),
      "object" => request_object(requester, auth.status, auth.quote_url, request_url),
      "result" => stamp_url(auth)
    }
  end

  @spec reject_activity(Status.t(), Profile.t(), String.t(), String.t()) :: map()
  def reject_activity(%Status{} = status, %Profile{} = requester, quote_url, request_url) do
    status = Repo.preload(status, :profile)
    author_url = Profiles.actor_url(status.profile)

    digest =
      :crypto.hash(:sha256, request_url) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    %{
      "@context" => @request_context,
      "id" => author_url <> "#rejects/quotes/" <> digest,
      "type" => "Reject",
      "actor" => author_url,
      "to" => Profiles.actor_url(requester),
      "object" => request_object(requester, status, quote_url, request_url)
    }
  end

  defp delete_activity(%Authorization{} = auth) do
    {context, object} = auth |> stamp_object() |> Map.pop("@context")

    %{
      "@context" => context,
      "id" => object["id"] <> "#delete",
      "type" => "Delete",
      "actor" => Profiles.actor_url(auth.profile),
      "to" => Profiles.actor_url(auth.actor),
      "object" => object
    }
  end

  defp request_object(requester, status, quote_url, request_url) do
    %{
      "id" => request_url,
      "type" => "QuoteRequest",
      "actor" => Profiles.actor_url(requester),
      "object" => status_url(status),
      "instrument" => quote_url
    }
  end

  defp status_url(%Status{} = s), do: s.uri || s.url
end
