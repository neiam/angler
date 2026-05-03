defmodule AnglerWeb.MastodonAPI.ApiV1Dot1Controller do
  @moduledoc """
  Pixelfed `/api/v1.1/...` namespace.

  These are the endpoints the Pixelfed mobile app fans out to during the
  post-login bootstrap (settings/security/password tabs) plus the user-
  initiated `report` action. Many of the pure-read ones return canonical
  empty / minimal shapes today; the seam is here so they can be filled in
  when the underlying tracking lands.
  """

  use AnglerWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts.User
  alias Angler.Follows.Follower
  alias Angler.OAuth.{Client, Token}
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Reports
  alias Angler.Repo
  alias Angler.Statuses.Status
  alias AnglerWeb.MastodonAPI.Account
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON
  alias AnglerWeb.Plugs.BearerAuth

  ## GET /api/v1.1/accounts/login-activity
  def login_activity(conn, _params) do
    # We don't track per-session login history yet. Empty array keeps the
    # mobile settings tab happy.
    json(conn, [])
  end

  ## GET /api/v1.1/accounts/two-factor
  def two_factor(conn, _params) do
    %{user: user} = BearerAuth.current_scope(conn)

    json(conn, %{
      "active" => not is_nil(user.two_factor_enabled_at),
      "setup_at" =>
        case user.two_factor_enabled_at do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end
    })
  end

  ## GET /api/v1.1/accounts/emails-from-pixelfed
  def emails_from_pixelfed(conn, _params), do: json(conn, [])

  ## GET /api/v1.1/accounts/apps-and-applications
  def apps_and_applications(conn, _params) do
    %{user: user, token: current} = BearerAuth.current_scope(conn)

    rows =
      Repo.all(
        from t in Token,
          join: c in Client,
          on: c.id == t.client_id,
          where: t.user_id == ^user.id,
          order_by: [desc: t.id],
          limit: 25,
          select: %{token: t, client: c}
      )

    body =
      Enum.map(rows, fn %{token: t, client: c} ->
        %{
          "id" => Integer.to_string(t.id),
          "current_session" => t.id == current.id,
          "name" => c.name,
          "scopes" => t.scopes,
          "revoked" => not is_nil(t.revoked_at),
          "created_at" => DateTime.to_iso8601(t.inserted_at),
          "expires_at" =>
            case t.expires_at do
              %DateTime{} = dt -> DateTime.to_iso8601(dt)
              _ -> nil
            end
        }
      end)

    json(conn, body)
  end

  ## GET /api/v1.1/accounts/mutuals/:id
  #
  # Profiles that *both* the viewer and `:id` are mutually following.
  def mutuals(conn, %{"id" => id}) do
    %{profile: viewer} = BearerAuth.current_scope(conn)

    with {:ok, target_id} <- parse_id(id),
         %Profile{} <- Profiles.get_profile(target_id) do
      ids =
        Repo.all(
          from f in Follower,
            where: f.following_id == ^viewer.id and not is_nil(f.accepted_at),
            select: f.profile_id
        )
        |> case do
          [] ->
            []

          viewer_following ->
            Repo.all(
              from f in Follower,
                where:
                  f.following_id == ^target_id and
                    f.profile_id in ^viewer_following and
                    not is_nil(f.accepted_at),
                select: f.profile_id
            )
        end

      profiles =
        case ids do
          [] -> []
          _ -> Repo.all(from p in Profile, where: p.id in ^ids and is_nil(p.status), limit: 24)
        end

      json(conn, Enum.map(profiles, &Account.render/1))
    else
      _ -> json(conn, [])
    end
  end

  ## GET /api/v1.1/accounts/username/:username
  def username_to_id(conn, %{"username" => username}) do
    case Profiles.lookup_acct(username) do
      %Profile{id: id} -> json(conn, %{"id" => Integer.to_string(id)})
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  ## GET /api/v1.1/accounts/:id/posts
  def posts(conn, %{"id" => id}) do
    %{profile: viewer} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         %Profile{} = profile <- Profiles.get_profile(int_id) do
      statuses =
        Repo.all(
          from s in Status,
            where:
              s.profile_id == ^profile.id and is_nil(s.deleted_at) and
                s.visibility in [:public, :unlisted],
            order_by: [desc: s.id],
            limit: 30,
            preload: [
              :profile,
              mentions: :profile,
              status_hashtags: :hashtag,
              media_attachments: []
            ]
        )

      json(conn, StatusJSON.render_many(statuses, viewer.id))
    else
      _ -> json(conn, [])
    end
  end

  ## DELETE /api/v1.1/accounts/avatar
  def delete_avatar(conn, _params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)

    {:ok, updated} =
      profile |> Ecto.Changeset.change(avatar_path: nil) |> Repo.update()

    body =
      Account.render(updated)
      |> Map.put("source", %{
        "privacy" => if(updated.is_private, do: "private", else: "public"),
        "sensitive" => false,
        "language" => user.language || "en",
        "note" => updated.bio || "",
        "fields" => []
      })

    json(conn, body)
  end

  ## POST /api/v1.1/accounts/change-password
  def change_password(conn, params) do
    %{user: user} = BearerAuth.current_scope(conn)

    cond do
      params["new_password"] != params["confirm_password"] ->
        validation_error(conn, %{"confirm_password" => ["does not match new_password"]})

      not User.valid_password?(user, params["current_password"] || "") ->
        validation_error(conn, %{"current_password" => ["The password you entered is incorrect"]})

      true ->
        case user
             |> User.change_password_changeset(%{password: params["new_password"]})
             |> Repo.update() do
          {:ok, _} -> json(conn, %{"message" => "Password changed"})
          {:error, cs} -> validation_error(conn, translate_errors(cs))
        end
    end
  end

  ## POST /api/v1.1/report
  def report(conn, params) do
    %{user: user} = BearerAuth.current_scope(conn)

    case Reports.submit(user, params) do
      {:ok, _report} ->
        json(conn, %{"msg" => "Successfully sent report", "code" => 200})

      {:error, :duplicate} ->
        report_error(conn, "Duplicate report", "ERROR_REPORT_DUPLICATE")

      {:error, :self_report} ->
        report_error(conn, "Cannot self report", "ERROR_NO_SELF_REPORTS")

      {:error, :invalid_type} ->
        report_error(conn, "Invalid report type", "ERROR_TYPE_INVALID")

      {:error, :invalid_object_type} ->
        report_error(conn, "Invalid object type", "ERROR_REPORT_OBJECT_TYPE_INVALID")

      {:error, :invalid_object_id} ->
        report_error(conn, "Invalid object id", "ERROR_INVALID_OBJECT_ID")

      {:error, :missing_object_id} ->
        report_error(conn, "Invalid or missing parameters", "ERROR_INVALID_PARAMS")

      {:error, :unsupported_object_type} ->
        report_error(conn, "Unsupported object type", "ERROR_REPORT_OBJECT_TYPE_INVALID")

      {:error, _} ->
        report_error(conn, "Invalid report", "ERROR_REPORT_INVALID")
    end
  end

  ## Internals

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  defp validation_error(conn, errors) when is_map(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "Validation failed", "errors" => errors})
  end

  defp report_error(conn, msg, code) do
    conn |> put_status(400) |> json(%{"error" => msg, "error_code" => code})
  end

  defp translate_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
