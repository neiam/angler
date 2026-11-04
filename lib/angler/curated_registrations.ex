defmodule Angler.CuratedRegistrations do
  @moduledoc """
  Curated registration: people apply for an account and an admin approves
  or rejects them. Mirrors upstream's `CuratedRegisterController` (applicant
  side) and `AdminCuratedRegisterController` (review side).

  The flow:

    1. `submit/2` stores the application (password already hashed) and emails
       a confirmation link.
    2. `confirm_email/2` marks the email verified; only then does the
       application enter the admin queue (and, if configured, admins are
       emailed).
    3. An admin may `request_details/3`; the applicant answers through the
       emailed one-time link with `respond/4`.
    4. `approve/2` creates the account via `Angler.Accounts.register_prehashed/2`
       and emails the applicant; `reject/3` closes the application, emailing
       them unless the admin chooses a silent rejection.

  Settings live under `config :angler, :curated_registration` (see
  `Angler.Instance.curated_config/2`).
  """

  import Ecto.Query, warn: false

  alias Angler.Accounts
  alias Angler.Accounts.User
  alias Angler.Auth.Username
  alias Angler.CuratedRegistrations.Activity
  alias Angler.CuratedRegistrations.CuratedRegister
  alias Angler.CuratedRegistrations.Template
  alias Angler.CuratedRegistrations.Workers.SendEmail
  alias Angler.Instance
  alias Angler.Mailer.CuratedRegisterEmail
  alias Angler.Repo

  @confirm_validity_days 7
  @resend_cooldown_hours 12
  @filters ~w(open all awaiting approved rejected responses)

  @doc "The admin queue filters, as upstream."
  @spec filters() :: [String.t()]
  def filters, do: @filters

  ## Applicant side

  @doc """
  Store a new application and email its confirmation link. Returns the
  changeset on any validation failure.
  """
  @spec submit(map(), String.t() | nil) ::
          {:ok, CuratedRegister.t()} | {:error, Ecto.Changeset.t()}
  def submit(attrs, ip \\ nil) do
    changeset =
      attrs
      |> CuratedRegister.submit_changeset()
      |> validate_username()
      |> validate_email_free()
      |> hash_password()

    {raw, hash} = gen_code()

    changeset
    |> Ecto.Changeset.put_change(:ip_address, ip)
    |> Ecto.Changeset.put_change(:verify_code_hash, hash)
    |> Ecto.Changeset.put_change(:code_sent_at, DateTime.utc_now())
    |> Repo.insert()
    |> case do
      {:ok, register} ->
        send_confirmation(register, raw)
        {:ok, register}

      error ->
        error
    end
  end

  defp validate_username(changeset) do
    Ecto.Changeset.validate_change(changeset, :username, fn :username, username ->
      cond do
        match?({:error, _}, Username.validate(username)) ->
          {:error, msg} = Username.validate(username)
          [username: msg]

        not Accounts.username_available?(username) or open_with?(:username, username) ->
          [username: "has already been taken"]

        true ->
          []
      end
    end)
  end

  defp validate_email_free(changeset) do
    Ecto.Changeset.validate_change(changeset, :email, fn :email, email ->
      cond do
        Angler.Admin.email_blocked?(email) ->
          [email: "is invalid"]

        Repo.exists?(from u in User, where: u.email == ^email) ->
          [email: "has already been taken"]

        open_with?(:email, email) ->
          [email: "has already been taken"]

        true ->
          []
      end
    end)
  end

  defp open_with?(field, value) do
    Repo.exists?(
      from r in CuratedRegister, where: field(r, ^field) == ^value and r.is_closed == false
    )
  end

  # Reuse the account password rules, then keep only the hash.
  defp hash_password(%Ecto.Changeset{valid?: true} = changeset) do
    password = Ecto.Changeset.get_change(changeset, :password)

    case User.change_password_changeset(%User{}, %{password: password}) do
      %Ecto.Changeset{valid?: true} = pw ->
        Ecto.Changeset.put_change(
          changeset,
          :password_hash,
          Ecto.Changeset.get_change(pw, :password_hash)
        )

      %Ecto.Changeset{errors: errors} ->
        Enum.reduce(errors, changeset, fn {:password, {msg, opts}}, cs ->
          Ecto.Changeset.add_error(cs, :password, msg, opts)
        end)
    end
  end

  defp hash_password(changeset), do: changeset

  defp send_confirmation(%CuratedRegister{} = r, raw) do
    url = base() <> "/auth/sign_up/confirm?" <> URI.encode_query(sid: r.id, code: raw)
    SendEmail.enqueue(r.email, CuratedRegisterEmail.confirm_email(r, url))
  end

  @doc """
  Confirm an application's email from the emailed link. The link is good for
  7 days after it was (re)sent.
  """
  @spec confirm_email(term(), term()) :: {:ok, CuratedRegister.t()} | {:error, :invalid}
  def confirm_email(sid, code) when is_binary(code) do
    cutoff = DateTime.add(DateTime.utc_now(), -@confirm_validity_days, :day)

    with {:ok, id} <- parse_id(sid),
         %CuratedRegister{} = r <-
           Repo.one(
             from r in CuratedRegister,
               where:
                 r.id == ^id and is_nil(r.email_verified_at) and r.is_closed == false and
                   r.code_sent_at > ^cutoff
           ),
         true <- code_matches?(r.verify_code_hash, code) do
      {:ok, r} =
        r
        |> Ecto.Changeset.change(email_verified_at: DateTime.utc_now(), verify_code_hash: nil)
        |> Repo.update()

      if Instance.curated_config(:notify_admin_on_verify, false) == true,
        do: notify_admins(CuratedRegisterEmail.admin_new_application(r))

      {:ok, r}
    else
      _ -> {:error, :invalid}
    end
  end

  def confirm_email(_sid, _code), do: {:error, :invalid}

  @doc """
  Re-send the confirmation link for an open, unverified application. At most
  once per 12 hours and `resend_confirmation_limit` times overall.
  """
  @spec resend_confirmation(String.t()) :: :ok | {:error, :not_found | :too_many | :too_soon}
  def resend_confirmation(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    case Repo.one(
           from r in CuratedRegister,
             where: r.email == ^email and r.is_closed == false and is_nil(r.email_verified_at)
         ) do
      nil ->
        {:error, :not_found}

      r ->
        resends =
          from a in Activity,
            where: a.register_id == ^r.id and a.type == "user_resend_email_confirmation"

        since = DateTime.add(DateTime.utc_now(), -@resend_cooldown_hours, :hour)

        cond do
          Repo.aggregate(resends, :count) >=
              Instance.curated_config(:resend_confirmation_limit, 5) ->
            {:error, :too_many}

          Repo.exists?(from a in resends, where: a.inserted_at > ^since) ->
            {:error, :too_soon}

          true ->
            {raw, hash} = gen_code()

            {:ok, r} =
              Repo.transaction(fn ->
                Repo.insert!(%Activity{register_id: r.id, type: "user_resend_email_confirmation"})

                r
                |> Ecto.Changeset.change(verify_code_hash: hash, code_sent_at: DateTime.utc_now())
                |> Repo.update!()
              end)

            send_confirmation(r, raw)
            :ok
        end
    end
  end

  @doc """
  Resolve an admin's open request for details from the emailed link, as
  `{register, activity}`. Fails once the applicant has replied.
  """
  @spec get_request(term(), term(), term()) ::
          {:ok, {CuratedRegister.t(), Activity.t()}} | {:error, :invalid}
  def get_request(sid, aid, code) when is_binary(code) do
    with {:ok, sid} <- parse_id(sid),
         {:ok, aid} <- parse_id(aid),
         %Activity{} = a <-
           Repo.one(
             from a in Activity,
               join: r in assoc(a, :register),
               where:
                 a.id == ^aid and a.register_id == ^sid and a.from_admin == true and
                   r.is_closed == false,
               preload: [register: r]
           ),
         true <- code_matches?(a.secret_code_hash, code),
         false <- Repo.exists?(from x in Activity, where: x.reply_to_id == ^a.id) do
      {:ok, {a.register, a}}
    else
      _ -> {:error, :invalid}
    end
  end

  def get_request(_, _, _), do: {:error, :invalid}

  @doc """
  The applicant's answer to `activity`. They must re-enter the email they
  applied with (upstream's concierge email check).
  """
  @spec respond(CuratedRegister.t(), Activity.t(), String.t(), String.t()) ::
          {:ok, Activity.t()} | {:error, :email_mismatch | :too_short | :too_long}
  def respond(%CuratedRegister{} = r, %Activity{} = a, email, response) do
    response = String.trim(response || "")

    cond do
      not Plug.Crypto.secure_compare(String.downcase(String.trim(email || "")), r.email) ->
        {:error, :email_mismatch}

      String.length(response) < 5 ->
        {:error, :too_short}

      String.length(response) > 1000 ->
        {:error, :too_long}

      true ->
        {:ok, reply} =
          Repo.transaction(fn ->
            reply =
              Repo.insert!(%Activity{
                register_id: r.id,
                reply_to_id: a.id,
                type: "user_response",
                message: response,
                from_user: true,
                action_required: true
              })

            r |> Ecto.Changeset.change(user_has_responded: true) |> Repo.update!()
            reply
          end)

        if Instance.curated_config(:notify_admin_on_user_response, false) == true,
          do: notify_admins(CuratedRegisterEmail.admin_user_response(r))

        {:ok, reply}
    end
  end

  ## Admin side

  @doc "Applications matching an admin queue filter (upstream `index`)."
  @spec list(String.t(), :asc | :desc) :: [CuratedRegister.t()]
  def list(filter \\ "open", sort \\ :asc) do
    CuratedRegister
    |> apply_filter(filter)
    |> order_by([r], [{^sort, r.id}])
    |> limit(200)
    |> Repo.all()
  end

  defp apply_filter(q, "all"), do: q

  defp apply_filter(q, "responses") do
    where(
      q,
      [r],
      r.is_closed == false and not is_nil(r.email_verified_at) and r.user_has_responded and
        r.is_awaiting_more_info
    )
  end

  defp apply_filter(q, "awaiting") do
    where(
      q,
      [r],
      r.is_closed == false and not r.is_rejected and not r.is_approved and
        not r.user_has_responded and r.is_awaiting_more_info
    )
  end

  defp apply_filter(q, "approved"), do: where(q, [r], r.is_closed and r.is_approved)
  defp apply_filter(q, "rejected"), do: where(q, [r], r.is_closed and r.is_rejected)

  defp apply_filter(q, _open) do
    where(
      q,
      [r],
      not r.is_rejected and (r.user_has_responded or not r.is_awaiting_more_info) and
        not is_nil(r.email_verified_at) and r.is_closed == false
    )
  end

  @doc "Number of applications waiting in the default `open` queue."
  @spec open_count() :: non_neg_integer()
  def open_count, do: CuratedRegister |> apply_filter("open") |> Repo.aggregate(:count)

  @doc "Fetch an application with its thread (oldest first), or nil."
  @spec get(term()) :: CuratedRegister.t() | nil
  def get(id) do
    case parse_id(id) do
      {:ok, id} ->
        activities =
          from a in Activity,
            where: a.type != "user_resend_email_confirmation",
            order_by: [asc: a.inserted_at, asc: a.id]

        CuratedRegister |> Repo.get(id) |> Repo.preload(activities: activities)

      :error ->
        nil
    end
  end

  @doc "Ask the applicant for more details; emails them a one-time reply link."
  @spec request_details(CuratedRegister.t(), User.t(), String.t()) ::
          {:ok, Activity.t()} | {:error, :unverified | :closed | :invalid_message}
  def request_details(%CuratedRegister{} = r, %User{} = admin, message) do
    message = String.trim(message || "")

    cond do
      is_nil(r.email_verified_at) ->
        {:error, :unverified}

      r.is_closed ->
        {:error, :closed}

      String.length(message) < 5 or String.length(message) > 3000 ->
        {:error, :invalid_message}

      true ->
        {raw, hash} = gen_code()

        {:ok, activity} =
          Repo.transaction(fn ->
            activity =
              Repo.insert!(%Activity{
                register_id: r.id,
                admin_id: admin.id,
                secret_code_hash: hash,
                type: "request_details",
                from_admin: true,
                message: message
              })

            r
            |> Ecto.Changeset.change(is_awaiting_more_info: true, user_has_responded: false)
            |> Repo.update!()

            activity
          end)

        url =
          base() <>
            "/auth/sign_up/concierge?" <>
            URI.encode_query(sid: r.id, id: activity.id, code: raw)

        SendEmail.enqueue(r.email, CuratedRegisterEmail.request_details(r, message, url))
        {:ok, activity}
    end
  end

  @doc """
  Approve: close the application, create the account and email the
  applicant. If the email already belongs to an account, the application is
  only closed (as upstream).
  """
  @spec approve(CuratedRegister.t(), User.t()) ::
          {:ok, CuratedRegister.t()} | {:error, :unverified | :closed | Ecto.Changeset.t()}
  def approve(%CuratedRegister{} = r, %User{} = admin) do
    cond do
      is_nil(r.email_verified_at) ->
        {:error, :unverified}

      r.is_closed ->
        {:error, :closed}

      true ->
        Repo.transaction(fn ->
          closed =
            r
            |> Ecto.Changeset.change(
              is_approved: true,
              is_closed: true,
              action_taken_at: DateTime.utc_now(),
              approved_by_admin_id: admin.id
            )
            |> Repo.update!()

          register_accepted!(r)
          closed
        end)
    end
  end

  # Inside approve's transaction: create the applicant's account (unless one
  # already exists for the email) and send the acceptance email.
  defp register_accepted!(%CuratedRegister{} = r) do
    unless Repo.exists?(from u in User, where: u.email == ^r.email) do
      attrs = %{
        email: r.email,
        username: r.username,
        register_ip: r.ip_address,
        register_source: "cur_onboarding"
      }

      case Accounts.register_prehashed(attrs, r.password_hash) do
        {:ok, _} -> SendEmail.enqueue(r.email, CuratedRegisterEmail.accepted(r))
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  @doc """
  Reject and close the application. `notify: false` is upstream's silent
  rejection; `message` is an optional note included in the email.
  """
  @spec reject(CuratedRegister.t(), User.t(), keyword()) ::
          {:ok, CuratedRegister.t()} | {:error, :unverified | :closed}
  def reject(%CuratedRegister{} = r, %User{} = _admin, opts \\ []) do
    cond do
      is_nil(r.email_verified_at) ->
        {:error, :unverified}

      r.is_closed ->
        {:error, :closed}

      true ->
        {:ok, closed} =
          r
          |> Ecto.Changeset.change(
            is_rejected: true,
            is_closed: true,
            action_taken_at: DateTime.utc_now()
          )
          |> Repo.update()

        if Keyword.get(opts, :notify, true),
          do: SendEmail.enqueue(r.email, CuratedRegisterEmail.rejected(r, opts[:message]))

        {:ok, closed}
    end
  end

  ## Helpers

  defp notify_admins(email) do
    from(u in User, where: u.is_admin == true and is_nil(u.status), select: u.email)
    |> Repo.all()
    |> Enum.each(&SendEmail.enqueue(&1, email))
  end

  defp gen_code do
    raw = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    {raw, :crypto.hash(:sha256, raw)}
  end

  defp code_matches?(hash, code) when is_binary(hash) and is_binary(code),
    do: Plug.Crypto.secure_compare(hash, :crypto.hash(:sha256, code))

  defp code_matches?(_, _), do: false

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp base, do: AnglerWeb.Endpoint.url()

  ## Reply templates (upstream AdminCuratedRegisterController template*)

  @doc "Every template, in display order."
  @spec list_templates() :: [Template.t()]
  def list_templates,
    do: Repo.all(from t in Template, order_by: [asc: t.order, asc: t.id])

  @doc "The templates offered while reviewing (upstream getActiveTemplates)."
  @spec active_templates() :: [Template.t()]
  def active_templates,
    do: Repo.all(from t in Template, where: t.is_active, order_by: [asc: t.order, asc: t.id])

  @spec get_template(term()) :: Template.t() | nil
  def get_template(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> Repo.get(Template, n)
      _ -> nil
    end
  end

  @spec change_template(Template.t(), map()) :: Ecto.Changeset.t()
  def change_template(%Template{} = t, attrs \\ %{}), do: Template.changeset(t, attrs)

  @spec save_template(Template.t(), map()) :: {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def save_template(%Template{} = t, attrs),
    do: t |> Template.changeset(attrs) |> Repo.insert_or_update()

  @spec delete_template(Template.t()) :: {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def delete_template(%Template{} = t), do: Repo.delete(t)
end
