defmodule Angler.Invites do
  @moduledoc """
  Admin-issued signup invitations. Backs the pre-registration check
  endpoints used by the mobile sign-up screen on closed instances.

  Issuance / management UI is not in this slice — operators seed the
  table directly until an admin namespace ships.
  """

  alias Angler.Invites.AdminInvite
  alias Angler.Repo

  @doc """
  Look up an invite by its code and return its current usability:

    * `{:ok, invite}` — code matched and is still usable
    * `{:error, :not_found | :expired | :exhausted}`
  """
  @spec verify(String.t()) ::
          {:ok, AdminInvite.t()} | {:error, :not_found | :expired | :exhausted}
  def verify(code) when is_binary(code) and code != "" do
    case Repo.get_by(AdminInvite, invite_code: code) do
      nil ->
        {:error, :not_found}

      %AdminInvite{} = invite ->
        cond do
          expired?(invite) -> {:error, :expired}
          exhausted?(invite) -> {:error, :exhausted}
          true -> {:ok, invite}
        end
    end
  end

  def verify(_), do: {:error, :not_found}

  defp expired?(%AdminInvite{expires_at: nil}), do: false

  defp expired?(%AdminInvite{expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) == :lt

  defp exhausted?(%AdminInvite{max_uses: nil}), do: false

  defp exhausted?(%AdminInvite{max_uses: max, uses: uses}) when is_integer(max),
    do: uses >= max
end
