defmodule AnglerWeb.LiveAuth do
  @moduledoc """
  `on_mount` hook for the public web LiveViews.

  The `:browser` pipeline runs `fetch_session`, so the plug session is handed
  to `mount/3` as the `session` map. This hook resolves the logged-in user (if
  any) the same way `AnglerWeb.Plugs.SessionAuth` does for controllers, and
  assigns `:current_user` / `:current_profile` for the layout + templates.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Angler.Accounts
  alias Angler.Profiles

  def on_mount(:mount_current_user, _params, session, socket) do
    user =
      case session["user_id"] do
        id when is_integer(id) -> Accounts.get_user(id)
        _ -> nil
      end

    profile = user && Profiles.get_profile(user.profile_id)

    {:cont,
     socket
     |> assign(:current_user, user)
     |> assign(:current_profile, profile)}
  end
end
