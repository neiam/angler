defmodule AnglerWeb.MastodonAPI.IarController do
  @moduledoc """
  Pixelfed in-app registration handshake.

    * GET  /api/v1.1/auth/iarpfc   — preflight check (open + iara flags)
    * POST /api/v1.1/auth/iar      — initiate (create user + email confirmation)
    * GET  /api/v1.1/auth/iarer    — email-link redirect → mobile deep link
    * POST /api/v1.1/auth/iarc     — confirm (verify tokens → access_token)

  Requires `X-PIXELFED-APP` header on the POST endpoints (proves the call
  came from a mobile app rather than a malicious page).

  Toggled at runtime via:

      config :angler, :open_registration, true
      config :angler, :in_app_registration_enabled, true
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts
  alias Angler.Accounts.User
  alias Angler.Auth.EmailVerification
  alias Angler.OAuth
  alias Angler.Repo

  @app_header "x-pixelfed-app"

  ## GET /auth/iarpfc

  def preflight(conn, _params) do
    json(conn, %{
      "open" => open_registration?(),
      "iara" => iar_allowed?()
    })
  end

  ## POST /auth/iar

  def initiate(conn, params) do
    cond do
      not open_registration?() ->
        not_found(conn)

      not iar_allowed?() ->
        not_found(conn)

      not has_app_header?(conn) ->
        forbidden(conn)

      true ->
        do_initiate(conn, params)
    end
  end

  defp do_initiate(conn, params) do
    case Accounts.register(%{
           "email" => params["email"],
           "username" => params["username"],
           "password" => params["password"],
           "name" => params["username"],
           "register_source" => "app"
         }) do
      {:ok, %{user: user}} ->
        # New users start unverified. Clear the auto-verify timestamp the
        # base register/1 sets so the iarc step has something to flip.
        {:ok, user} =
          user |> Ecto.Changeset.change(email_verified_at: nil) |> Repo.update()

        user_token = Base.url_encode64(:crypto.strong_rand_bytes(30), padding: false)
        random_token = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

        {:ok, _verify} =
          %{
            user_id: user.id,
            email: user.email,
            user_token: user_token,
            random_token: random_token
          }
          |> EmailVerification.changeset()
          |> Repo.insert()

        deliver_email(user, user_token, random_token)

        json(conn, %{"success" => true})

      {:error, :email_domain_blocked} ->
        validation_error(conn, %{"email" => ["domain is blocked"]})

      {:error, %Ecto.Changeset{} = cs} ->
        validation_error(conn, translate_errors(cs))

      {:error, reason} ->
        validation_error(conn, %{"_" => [to_string(reason)]})
    end
  end

  ## GET /auth/iarer

  def email_redirect(conn, %{"ut" => ut, "rt" => rt, "ea" => ea}) do
    # Redirect into the Pixelfed mobile deep link so the verification form
    # can re-submit the tokens. Email-link UX matches Pixelfed exactly.
    qs =
      URI.encode_query(%{
        "ut" => ut,
        "rt" => rt,
        "domain" => host(),
        "ea" => ea
      })

    redirect(conn, external: "pixelfed://confirm-account/#{ut}?#{qs}")
  end

  def email_redirect(conn, _), do: bad_request(conn, "missing parameters")

  ## POST /auth/iarc

  def confirm(conn, %{"user_token" => ut, "random_token" => rt, "email" => email}) do
    cond do
      not open_registration?() ->
        not_found(conn)

      not iar_allowed?() ->
        not_found(conn)

      not has_app_header?(conn) ->
        forbidden(conn)

      true ->
        do_confirm(conn, ut, rt, String.downcase(email))
    end
  end

  def confirm(conn, _), do: validation_error(conn, %{"_" => ["missing parameters"]})

  defp do_confirm(conn, ut, rt, email) do
    case Repo.get_by(EmailVerification, email: email, user_token: ut, random_token: rt) do
      nil ->
        invalid_tokens(conn)

      verify ->
        if EmailVerification.valid?(verify) do
          mark_user_verified!(verify)

          %{client: client} = OAuth.first_party_client!()
          user = Repo.get!(User, verify.user_id)

          {:ok, %{access: access}} =
            OAuth.issue_token(user, client, scopes: ["read", "write", "follow", "push"])

          Repo.delete(verify)

          json(conn, %{"access_token" => access})
        else
          Repo.delete(verify)
          invalid_tokens(conn)
        end
    end
  end

  ## Internals

  defp open_registration?, do: Angler.Instance.open_registration?()

  defp iar_allowed?,
    do: Application.get_env(:angler, :in_app_registration_enabled, false) == true

  defp has_app_header?(conn) do
    case Plug.Conn.get_req_header(conn, @app_header) do
      [_v | _] -> true
      _ -> false
    end
  end

  defp deliver_email(user, ut, rt) do
    base = AnglerWeb.Endpoint.url()

    qs =
      URI.encode_query(%{
        "ut" => ut,
        "rt" => rt,
        "ea" => Base.encode64(user.email)
      })

    deep_link = base <> "/api/v1.1/auth/iarer?" <> qs

    Angler.Mailer.AppCodeEmail.send_iar_confirmation(user.email, deep_link)
  rescue
    _ ->
      # Mailer might not be available (or AppCodeEmail might not have the
      # iar function); registration shouldn't crash. Operators can read
      # `email_verifications` directly during dev.
      :ok
  end

  defp mark_user_verified!(verify) do
    Repo.update_all(
      from(u in User, where: u.id == ^verify.user_id),
      set: [email_verified_at: DateTime.utc_now()]
    )
  end

  defp translate_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  defp host do
    AnglerWeb.Endpoint.url() |> URI.parse() |> Map.get(:host) || "localhost"
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{"error" => "Not found"})
  defp forbidden(conn), do: conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

  defp invalid_tokens(conn),
    do: conn |> put_status(:forbidden) |> json(%{"error" => "Invalid tokens"})

  defp bad_request(conn, msg),
    do: conn |> put_status(:bad_request) |> json(%{"error" => msg})

  defp validation_error(conn, errors),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{"error" => "Validation failed", "errors" => errors})
end
