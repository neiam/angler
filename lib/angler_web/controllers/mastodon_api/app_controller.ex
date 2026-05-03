defmodule AnglerWeb.MastodonAPI.AppController do
  @moduledoc """
  POST /api/v1/apps + GET /api/v1/apps/verify_credentials.
  """

  use AnglerWeb, :controller

  alias Angler.OAuth
  alias Angler.OAuth.Client
  alias AnglerWeb.Plugs.BearerAuth

  def create(conn, params) do
    case OAuth.register_client(params) do
      {:ok, %{client: client, secret: secret}} ->
        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> json(render_create(client, secret))

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(422)
        |> json(%{
          "error" => "Validation failed",
          "errors" => translate_errors(cs)
        })
    end
  end

  def verify(conn, _params) do
    case BearerAuth.current_scope(conn) do
      %{token: token} = _scope ->
        if token.user_id do
          client = Angler.Repo.get(Client, token.client_id)
          json(conn, render_verify(client))
        else
          conn |> put_status(403) |> json(%{"error" => "user-attached token required"})
        end

      _ ->
        conn |> put_status(401) |> json(%{"error" => "unauthorized"})
    end
  end

  ## Internals

  defp render_create(%Client{} = c, secret) do
    %{
      "id" => Integer.to_string(c.id),
      "name" => c.name,
      "website" => c.website,
      "redirect_uri" => Enum.join(c.redirect_uris, ","),
      "redirect_uris" => c.redirect_uris,
      "scopes" => c.scopes,
      "client_id" => Integer.to_string(c.id),
      "client_secret" => secret,
      "vapid_key" => nil
    }
  end

  defp render_verify(%Client{} = c) do
    %{"name" => c.name, "website" => c.website, "vapid_key" => nil}
  end

  defp render_verify(_), do: %{"name" => nil, "website" => nil, "vapid_key" => nil}

  defp translate_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
