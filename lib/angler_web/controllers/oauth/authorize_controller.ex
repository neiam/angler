defmodule AnglerWeb.OAuth.AuthorizeController do
  @moduledoc """
  GET/POST `/oauth/authorize` — the OAuth authorization endpoint.

  GET renders a consent form (or redirects to login when no session). POST
  processes the consent: on approval, mints an authorization code and either
  redirects to `redirect_uri?code=...` or renders the code on a confirmation
  page when the requested redirect is `urn:ietf:wg:oauth:2.0:oob`.
  """

  use AnglerWeb, :controller

  alias Angler.OAuth
  alias Angler.OAuth.Client

  @oob "urn:ietf:wg:oauth:2.0:oob"

  def show(conn, params) do
    case authorize_params(params) do
      {:ok, ctx} ->
        case conn.assigns[:current_user] do
          nil ->
            redirect(conn, to: ~p"/session/login?next=#{request_with_query(conn)}")

          user ->
            render(conn, :show, ctx: ctx, error: nil, current_user: user)
        end

      {:error, msg} ->
        conn |> put_status(400) |> render(:error, message: msg)
    end
  end

  def authorize(conn, %{"approve" => "true"} = params) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        redirect(conn, to: ~p"/session/login?next=#{request_with_query(conn)}")

      true ->
        case authorize_params(params) do
          {:ok, ctx} ->
            {:ok, %{code: code}} =
              OAuth.create_authorization_code(user, ctx.client, ctx.scopes,
                redirect_uri: ctx.redirect_uri,
                code_challenge: params["code_challenge"],
                code_challenge_method: params["code_challenge_method"]
              )

            if ctx.redirect_uri == @oob do
              render(conn, :oob, code: code)
            else
              qs =
                URI.encode_query(
                  Enum.reject(
                    [{"code", code}, {"state", params["state"]}],
                    fn {_, v} -> v in [nil, ""] end
                  )
                )

              redirect(conn, external: append_query(ctx.redirect_uri, qs))
            end

          {:error, msg} ->
            conn |> put_status(400) |> render(:error, message: msg)
        end
    end
  end

  def authorize(conn, params) do
    # Deny / no approve flag → redirect with error (or render error page for OOB).
    case authorize_params(params) do
      {:ok, ctx} when ctx.redirect_uri == @oob ->
        render(conn, :error, message: "Authorization denied.")

      {:ok, ctx} ->
        qs =
          URI.encode_query(
            Enum.reject(
              [{"error", "access_denied"}, {"state", params["state"]}],
              fn {_, v} -> v in [nil, ""] end
            )
          )

        redirect(conn, external: append_query(ctx.redirect_uri, qs))

      {:error, msg} ->
        conn |> put_status(400) |> render(:error, message: msg)
    end
  end

  ## Internals

  defp authorize_params(params) do
    with {:ok, client} <- fetch_client(params["client_id"]),
         {:ok, redirect_uri} <- check_redirect(client, params["redirect_uri"]),
         {:ok, scopes} <- check_scopes(client, params["scope"]),
         :ok <- check_response_type(params["response_type"]) do
      {:ok, %{client: client, redirect_uri: redirect_uri, scopes: scopes}}
    end
  end

  defp fetch_client(id) do
    case OAuth.get_client(id) do
      %Client{revoked: false} = c -> {:ok, c}
      _ -> {:error, "unknown client"}
    end
  end

  defp check_redirect(_client, nil), do: {:error, "redirect_uri is required"}
  defp check_redirect(_client, ""), do: {:error, "redirect_uri is required"}

  defp check_redirect(%Client{redirect_uris: registered}, requested) do
    if requested in registered, do: {:ok, requested}, else: {:error, "redirect_uri not allowed"}
  end

  defp check_scopes(%Client{scopes: registered}, nil), do: {:ok, registered}
  defp check_scopes(%Client{scopes: registered}, ""), do: {:ok, registered}

  defp check_scopes(%Client{scopes: registered}, requested) when is_binary(requested) do
    parts = String.split(requested, [" ", ","], trim: true)
    bad = parts -- registered

    if bad == [],
      do: {:ok, parts},
      else: {:error, "scope not granted to client: #{Enum.join(bad, " ")}"}
  end

  defp check_response_type(nil), do: {:error, "response_type is required"}
  defp check_response_type("code"), do: :ok
  defp check_response_type(_), do: {:error, "unsupported response_type"}

  defp request_with_query(conn) do
    case conn.query_string do
      "" -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end

  defp append_query(uri, qs) do
    case URI.parse(uri) do
      %URI{query: nil} = u -> URI.to_string(%{u | query: qs})
      %URI{query: existing} = u -> URI.to_string(%{u | query: existing <> "&" <> qs})
    end
  end
end
