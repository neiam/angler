defmodule AnglerWeb.Plugs.SessionAuth do
  @moduledoc """
  Look up a `:user_id` from the session and assign the current user.

  Sets `conn.assigns[:current_user]` to a `%User{}` or `nil`. Does not
  redirect — controllers decide whether unauthenticated visitors are allowed.
  """

  import Plug.Conn
  alias Angler.Accounts

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    user =
      case get_session(conn, :user_id) do
        id when is_integer(id) -> Accounts.get_user(id)
        _ -> nil
      end

    assign(conn, :current_user, user)
  end
end
