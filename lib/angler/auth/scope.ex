defmodule Angler.Auth.Scope do
  @moduledoc """
  Authentication context for an authenticated request.

  Lives on `conn.assigns.current_scope`. Phoenix's gen_auth convention; AGENTS.md
  also requires that LiveView templates pass `current_scope` to `<Layouts.app>`
  (we follow the same naming for JSON controllers for consistency).

  An anonymous request has no `current_scope` assign at all — controllers should
  pattern-match on its presence rather than defaulting to "anonymous user".
  """

  defstruct [:user, :profile, :token, :scopes]

  @type t :: %__MODULE__{
          user: Angler.Accounts.User.t(),
          profile: Angler.Profiles.Profile.t(),
          token: Angler.OAuth.Token.t(),
          scopes: [String.t()]
        }

  @doc """
  Whether the scope satisfies a required scope name.

  Mastodon's scope tree is hierarchical: a token granted `read` covers
  `read:accounts`, `read:statuses`, etc. A token granted `read:accounts` only
  covers exactly that.
  """
  @spec has_scope?(t() | nil, String.t()) :: boolean()
  def has_scope?(nil, _required), do: false

  def has_scope?(%__MODULE__{scopes: scopes}, required) when is_binary(required) do
    Enum.any?(scopes, fn granted ->
      granted == required or String.starts_with?(required, granted <> ":")
    end)
  end
end
