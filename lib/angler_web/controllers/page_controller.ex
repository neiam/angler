defmodule AnglerWeb.PageController do
  use AnglerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  # /.well-known/change-password — RFC 8615 redirect to wherever the password
  # settings page lives. Matches Pixelfed's `Route::redirect`.
  def redirect_to_password_settings(conn, _params) do
    redirect(conn, to: "/settings/password")
  end
end
