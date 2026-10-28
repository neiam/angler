defmodule Angler.Profiles.DomainBlocks do
  @moduledoc "User-level domain block lifecycle."

  import Ecto.Query, warn: false

  alias Angler.Profiles.{DomainBlock, Profile}
  alias Angler.Repo

  @spec list(integer(), pos_integer()) :: [String.t()]
  def list(profile_id, limit \\ 100) do
    Repo.all(
      from b in DomainBlock,
        where: b.profile_id == ^profile_id,
        order_by: [desc: b.id],
        limit: ^limit,
        select: b.domain
    )
  end

  @spec block(Profile.t(), String.t()) :: :ok
  def block(%Profile{id: pid}, domain) when is_binary(domain) do
    %{profile_id: pid, domain: String.downcase(domain)}
    |> DomainBlock.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :domain])

    :ok = Angler.Quotes.revoke_for_domain(pid, domain)
    Angler.FeaturedCollections.revoke_for_domain(pid, domain)
  end

  @doc "Whether `profile_id` blocks `domain`."
  @spec blocked?(integer(), String.t()) :: boolean()
  def blocked?(profile_id, domain) when is_binary(domain) do
    domain = String.downcase(domain)

    Repo.exists?(
      from b in DomainBlock, where: b.profile_id == ^profile_id and b.domain == ^domain
    )
  end

  def blocked?(_, _), do: false

  @spec unblock(Profile.t(), String.t()) :: :ok
  def unblock(%Profile{id: pid}, domain) when is_binary(domain) do
    domain = String.downcase(domain)

    {_, _} =
      from(b in DomainBlock, where: b.profile_id == ^pid and b.domain == ^domain)
      |> Repo.delete_all()

    :ok
  end
end
