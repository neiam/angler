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

  alias Angler.Accounts
  alias Angler.Accounts.Settings
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
  # Upstream (5e0171cf1) added `filter=active|revoked|all`, `limit` (≤40)
  # and `max_id` paging with a Link header, plus a `status` field.
  def apps_and_applications(conn, params) do
    %{user: user, token: current} = BearerAuth.current_scope(conn)
    limit = params["limit"] |> parse_int(25) |> min(40) |> max(1)
    now = DateTime.utc_now()

    query =
      from t in Token,
        join: c in Client,
        on: c.id == t.client_id,
        where: t.user_id == ^user.id,
        order_by: [desc: t.id],
        limit: ^limit,
        select: %{token: t, client: c}

    query =
      case params["filter"] do
        "active" ->
          from [t, _] in query,
            where: is_nil(t.revoked_at) and (is_nil(t.expires_at) or t.expires_at > ^now)

        "revoked" ->
          from [t, _] in query, where: not is_nil(t.revoked_at)

        _ ->
          query
      end

    query =
      case parse_int(params["max_id"], nil) do
        nil -> query
        max_id -> from [t, _] in query, where: t.id < ^max_id
      end

    rows = Repo.all(query)

    body =
      Enum.map(rows, fn %{token: t, client: c} ->
        %{
          "id" => Integer.to_string(t.id),
          "current_session" => t.id == current.id,
          "name" => c.name,
          "scopes" => t.scopes,
          "revoked" => not is_nil(t.revoked_at),
          "status" => token_status(t, now),
          "created_at" => DateTime.to_iso8601(t.inserted_at),
          "expires_at" =>
            case t.expires_at do
              %DateTime{} = dt -> DateTime.to_iso8601(dt)
              _ -> nil
            end
        }
      end)

    conn =
      case List.last(rows) do
        %{token: last} when length(rows) == limit ->
          next =
            AnglerWeb.Endpoint.url() <>
              conn.request_path <>
              "?" <>
              URI.encode_query(
                conn.query_params
                |> Map.take(["filter", "limit"])
                |> Map.put("max_id", Integer.to_string(last.id))
              )

          put_resp_header(conn, "link", ~s(<#{next}>; rel="next"))

        _ ->
          conn
      end

    json(conn, body)
  end

  defp token_status(%Token{revoked_at: %DateTime{}}, _now), do: "revoked"

  defp token_status(%Token{expires_at: %DateTime{} = at}, now) do
    if DateTime.compare(at, now) == :gt, do: "active", else: "expired"
  end

  defp token_status(_, _), do: "active"

  ## POST /api/v1.1/accounts/apps-and-applications/:id/revoke
  #
  # Revoke one of the user's app sessions — access and refresh token, which
  # share a row. Not the one making the request (upstream answers 422).
  def revoke_app(conn, %{"id" => id}) do
    %{user: user, token: current} = BearerAuth.current_scope(conn)

    with {:ok, token_id} <- parse_id(id),
         %Token{user_id: uid} = token when uid == user.id <- Repo.get(Token, token_id) do
      if token.id == current.id do
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => "You can't revoke the session you're using."})
      else
        Angler.OAuth.revoke(token)

        json(conn, %{
          "id" => Integer.to_string(token.id),
          "revoked" => true,
          "status" => "revoked"
        })
      end
    else
      _ -> conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
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
  #
  # Despite the legacy name, Pixelfed returns the **full account** here, not a
  # bare `{id}` — `AccountService::get($accountId)` upstream. The mobile app's
  # `getAccountByUsername` (profile-by-handle navigation, e.g. tapping a
  # mention) types the response as a full `Account` and renders it directly, so
  # returning only `{id}` leaves the profile header empty. Honor `?_pe=1` and
  # attach private settings when it's the caller's own profile, matching
  # `AccountController.show`.
  def username_to_id(conn, %{"username" => username} = params) do
    case Profiles.lookup_acct(username) do
      %Profile{} = profile ->
        json(conn, Account.render(profile, account_render_opts(conn, params, profile)))

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  defp account_render_opts(conn, params, %Profile{} = profile) do
    if Map.get(params, "_pe") in ["1", "true", 1, true] do
      case BearerAuth.current_scope(conn) do
        %{user: %{} = user, profile: %{id: pid}} when pid == profile.id ->
          [pe: true, user: user, settings: Settings.account_settings(user.id)]

        _ ->
          [pe: true]
      end
    else
      []
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

  ## DELETE /api/v1.1/accounts/header
  def delete_header(conn, _params) do
    %{user: user, profile: profile} = BearerAuth.current_scope(conn)

    {:ok, updated} =
      profile |> Ecto.Changeset.change(header_path: nil) |> Repo.update()

    body =
      Account.render(updated)
      |> Map.put("source", %{
        "privacy" => if(updated.is_private, do: "private", else: "public"),
        "sensitive" => false,
        "language" => user.language || "en",
        "note" => updated.bio_text || "",
        "fields" => []
      })

    json(conn, body)
  end

  ## POST /api/v1.1/accounts/change-password
  # `revoke_other_sessions` (upstream) signs out every other app and device.
  def change_password(conn, params) do
    %{user: user, token: current} = BearerAuth.current_scope(conn)

    cond do
      params["new_password"] != params["confirm_password"] ->
        validation_error(conn, %{"confirm_password" => ["does not match new_password"]})

      not User.valid_password?(user, params["current_password"] || "") ->
        validation_error(conn, %{"current_password" => ["The password you entered is incorrect"]})

      true ->
        case user
             |> User.change_password_changeset(%{password: params["new_password"]})
             |> Repo.update() do
          {:ok, _} ->
            if params["revoke_other_sessions"] in [true, "true", "1", 1],
              do: Angler.OAuth.revoke_all_for_user(user.id, except: current.id)

            json(conn, %{"message" => "Password changed"})

          {:error, cs} ->
            validation_error(conn, translate_errors(cs))
        end
    end
  end

  ## POST /api/v1.1/accounts/email
  def change_email(conn, params) do
    %{user: user} = BearerAuth.current_scope(conn)

    case Accounts.change_email(user, params["current_password"], params["email"] || "") do
      {:ok, _updated} ->
        json(conn, %{"message" => "Email updated"})

      {:error, :invalid_password} ->
        validation_error(conn, %{"current_password" => ["The password you entered is incorrect"]})

      {:error, %Ecto.Changeset{} = cs} ->
        validation_error(conn, translate_errors(cs))
    end
  end

  ## POST /api/v1.1/accounts/disable
  def disable_account(conn, params) do
    %{user: user} = BearerAuth.current_scope(conn)

    case Accounts.disable_own_account(user, params["password"]) do
      {:ok, _} ->
        json(conn, %{"message" => "Account disabled"})

      {:error, :invalid_password} ->
        validation_error(conn, %{"password" => ["The password you entered is incorrect"]})
    end
  end

  ## POST /api/v1.1/accounts/delete
  # Also serves upstream's `POST /api/v2.1/account/remove/permanent`, which
  # names the password `current_password`. Every session is signed out.
  def delete_account(conn, params) do
    %{user: user} = BearerAuth.current_scope(conn)

    case Accounts.delete_own_account(user, params["password"] || params["current_password"]) do
      {:ok, _} ->
        Angler.OAuth.revoke_all_for_user(user.id)
        json(conn, %{"message" => "Account scheduled for deletion"})

      {:error, :deletion_disabled} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Account deletion is disabled"})

      {:error, :invalid_password} ->
        validation_error(conn, %{"password" => ["The password you entered is incorrect"]})
    end
  end

  ## Archive

  def archive_add(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         {:ok, _} <- Angler.Statuses.archive_local(int_id, profile) do
      json(conn, [200])
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

      {:error, :unarchivable} ->
        validation_error(conn, %{"id" => ["cannot archive replies or reblogs"]})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def archive_remove(conn, %{"id" => id}) do
    %{profile: profile} = BearerAuth.current_scope(conn)

    with {:ok, int_id} <- parse_id(id),
         {:ok, _} <- Angler.Statuses.unarchive_local(int_id, profile) do
      json(conn, [200])
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Forbidden"})

      _ ->
        conn |> put_status(:not_found) |> json(%{"error" => "Record not found"})
    end
  end

  def archive_list(conn, _params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    statuses = Angler.Statuses.list_archived(profile.id)
    json(conn, StatusJSON.render_many(statuses, profile.id))
  end

  ## POST /api/v1.1/status/create
  ##
  ## Pixelfed-shape one-shot status creation: a single multipart `file`
  ## plus optional caption + visibility. Internally we still go through
  ## `Media.upload/3` then `Statuses.create_local/2` so feed-fanout and
  ## federation behave exactly the same as the standard Mastodon path.
  def status_create_pixelfed(conn, params) do
    %{profile: profile} = BearerAuth.current_scope(conn)
    upload = params["file"]

    cond do
      is_nil(upload) ->
        validation_error(conn, %{"file" => ["is required"]})

      true ->
        case Angler.Media.upload(profile, upload, %{}) do
          {:ok, asset} ->
            create_local_with_media(conn, profile, params, asset.id)

          {:error, reason} ->
            validation_error(conn, %{"file" => [to_string(reason)]})
        end
    end
  end

  defp create_local_with_media(conn, profile, params, media_id) do
    visibility =
      case params["visibility"] do
        v when v in ["public", "unlisted", "private"] -> v
        _ -> "public"
      end

    attrs = %{
      "status" => to_string(params["status"] || ""),
      "media_ids" => [Integer.to_string(media_id)],
      "sensitive" => params["sensitive"] || false,
      "spoiler_text" => params["spoiler_text"],
      "visibility" => visibility
    }

    case Angler.Statuses.create_local(profile, attrs) do
      {:ok, status} ->
        Angler.Timelines.Workers.FeedInsert.enqueue(status.id)
        Angler.Statuses.Workers.StatusDeliver.enqueue_for(status)

        body =
          StatusJSON.render(status, profile.id)
          |> Map.put("favourited", false)
          |> Map.put("bookmarked", false)
          |> Map.put("language", "en")
          |> Map.put("card", nil)

        json(conn, body)

      {:error, %Ecto.Changeset{} = cs} ->
        validation_error(conn, translate_errors(cs))

      {:error, reason} ->
        validation_error(conn, %{"status" => [to_string(reason)]})
    end
  end

  ## GET /api/v1.1/nag/state
  ##
  ## Pixelfed shows a soft-nag in the mobile UI when push notifications
  ## are available but the user hasn't opted in. We expose the same
  ## boolean shape; flips on when `:expo_push_enabled` is set.
  def nag_state(conn, _params) do
    json(conn, %{"active" => Angler.Push.Expo.enabled?()})
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

      {:error, :message_too_long} ->
        report_error(conn, "Message is too long", "ERROR_MESSAGE_TOO_LONG")

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

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

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
