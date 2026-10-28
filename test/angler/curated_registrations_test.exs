defmodule Angler.CuratedRegistrationsTest do
  use Angler.DataCase, async: false
  use Oban.Testing, repo: Angler.Repo

  alias Angler.Accounts
  alias Angler.CuratedRegistrations
  alias Angler.CuratedRegistrations.Activity
  alias Angler.CuratedRegistrations.CuratedRegister
  alias Angler.CuratedRegistrations.Workers.SendEmail

  @attrs %{
    "username" => "newbie",
    "email" => "Newbie@Example.com",
    "password" => "verysecret123",
    "password_confirmation" => "verysecret123",
    "reason_to_join" => "I take a lot of photos of birds and want to share them.",
    "agree" => "true"
  }

  defp admin do
    {:ok, %{user: user}} =
      Accounts.register(%{username: "boss", email: "boss@example.com", password: "verysecret123"},
        approved: true
      )

    {:ok, user} = Accounts.set_admin(user, true)
    user
  end

  # The raw code only travels in the email, so tests read it back from the job.
  defp emailed_link(to, path) do
    [job | _] =
      all_enqueued(worker: SendEmail)
      |> Enum.filter(&(&1.args["to"] == to and &1.args["text"] =~ path))
      |> Enum.reverse()

    [url] = Regex.run(~r{https?://\S+#{Regex.escape(path)}\S*}, job.args["text"])
    URI.decode_query(URI.parse(url).query)
  end

  defp submitted do
    {:ok, r} = CuratedRegistrations.submit(@attrs, "198.51.100.7")
    r
  end

  defp verified do
    r = submitted()
    %{"sid" => sid, "code" => code} = emailed_link(r.email, "/auth/sign_up/confirm")
    {:ok, r} = CuratedRegistrations.confirm_email(sid, code)
    r
  end

  describe "submit/2" do
    test "stores a hashed password and emails a confirmation link" do
      r = submitted()

      assert r.email == "newbie@example.com"
      assert r.ip_address == "198.51.100.7"
      assert Argon2.verify_pass("verysecret123", r.password_hash)
      assert_enqueued(worker: SendEmail, args: %{"to" => "newbie@example.com"})
      assert %{"sid" => _, "code" => _} = emailed_link(r.email, "/auth/sign_up/confirm")
    end

    test "validates the application shape" do
      {:error, cs} =
        CuratedRegistrations.submit(%{
          @attrs
          | "password_confirmation" => "nope",
            "reason_to_join" => "short",
            "agree" => "false"
        })

      errors = errors_on(cs)
      assert errors.password_confirmation
      assert errors.reason_to_join
      assert errors.agree
    end

    test "rejects usernames and emails already in use" do
      _ = submitted()

      {:error, cs} = CuratedRegistrations.submit(@attrs)
      assert errors_on(cs).email
      assert errors_on(cs).username

      {:ok, _} =
        Accounts.register(%{
          username: "taken",
          email: "taken@example.com",
          password: "pw12345678"
        })

      {:error, cs} =
        CuratedRegistrations.submit(%{
          @attrs
          | "username" => "taken",
            "email" => "taken@example.com"
        })

      assert errors_on(cs).email
      assert errors_on(cs).username
    end

    test "a rejected applicant may apply again" do
      r = verified()
      {:ok, _} = CuratedRegistrations.reject(r, admin(), notify: false)
      assert {:ok, %CuratedRegister{}} = CuratedRegistrations.submit(@attrs)
    end
  end

  describe "confirm_email/2" do
    test "verifies with the emailed code, once" do
      r = submitted()
      %{"sid" => sid, "code" => code} = emailed_link(r.email, "/auth/sign_up/confirm")

      assert {:error, :invalid} = CuratedRegistrations.confirm_email(sid, "wrong")

      assert {:ok, %{email_verified_at: %DateTime{}}} =
               CuratedRegistrations.confirm_email(sid, code)

      assert {:error, :invalid} = CuratedRegistrations.confirm_email(sid, code)
    end

    test "expires after 7 days" do
      r = submitted()
      %{"sid" => sid, "code" => code} = emailed_link(r.email, "/auth/sign_up/confirm")

      r
      |> Ecto.Changeset.change(code_sent_at: DateTime.add(DateTime.utc_now(), -8, :day))
      |> Repo.update!()

      assert {:error, :invalid} = CuratedRegistrations.confirm_email(sid, code)
    end

    test "emails admins when configured" do
      boss = admin()
      Application.put_env(:angler, :curated_registration, notify_admin_on_verify: true)
      on_exit(fn -> Application.delete_env(:angler, :curated_registration) end)

      _ = verified()
      assert_enqueued(worker: SendEmail, args: %{"to" => boss.email})
    end
  end

  describe "resend_confirmation/1" do
    test "re-sends at most once per 12 hours" do
      r = submitted()
      assert :ok = CuratedRegistrations.resend_confirmation("NEWBIE@example.com")
      assert {:error, :too_soon} = CuratedRegistrations.resend_confirmation(r.email)
      assert {:error, :not_found} = CuratedRegistrations.resend_confirmation("x@example.com")
    end

    test "stops after the overall limit" do
      r = submitted()
      Application.put_env(:angler, :curated_registration, resend_confirmation_limit: 1)
      on_exit(fn -> Application.delete_env(:angler, :curated_registration) end)

      Repo.insert!(%Activity{
        register_id: r.id,
        type: "user_resend_email_confirmation",
        inserted_at: DateTime.add(DateTime.utc_now(), -1, :day)
      })

      assert {:error, :too_many} = CuratedRegistrations.resend_confirmation(r.email)
    end
  end

  describe "list/1" do
    test "the open queue holds only verified, undecided applications" do
      unverified = submitted()
      assert CuratedRegistrations.list("open") == []
      assert [%{id: id}] = CuratedRegistrations.list("all")
      assert id == unverified.id

      _ = CuratedRegistrations.confirm_email(unverified.id, "nope")
      %{"sid" => sid, "code" => code} = emailed_link(unverified.email, "/auth/sign_up/confirm")
      {:ok, _} = CuratedRegistrations.confirm_email(sid, code)
      assert [_] = CuratedRegistrations.list("open")
      assert CuratedRegistrations.open_count() == 1
    end
  end

  describe "request_details/3 and respond/4" do
    test "the applicant answers through the one-time link" do
      r = verified()
      boss = admin()

      assert {:error, :invalid_message} = CuratedRegistrations.request_details(r, boss, "hi")
      {:ok, ask} = CuratedRegistrations.request_details(r, boss, "Which birds, exactly?")

      assert CuratedRegistrations.list("awaiting") |> Enum.map(& &1.id) == [r.id]

      %{"sid" => sid, "id" => aid, "code" => code} =
        emailed_link(r.email, "/auth/sign_up/concierge")

      assert aid == to_string(ask.id)
      assert {:error, :invalid} = CuratedRegistrations.get_request(sid, aid, "bad")
      {:ok, {reg, activity}} = CuratedRegistrations.get_request(sid, aid, code)

      assert {:error, :email_mismatch} =
               CuratedRegistrations.respond(reg, activity, "other@example.com", "Herons!")

      assert {:ok, %Activity{from_user: true}} =
               CuratedRegistrations.respond(reg, activity, "newbie@example.com", "Herons!")

      assert {:error, :invalid} = CuratedRegistrations.get_request(sid, aid, code)
      assert CuratedRegistrations.list("responses") |> Enum.map(& &1.id) == [r.id]
      assert [_, _] = CuratedRegistrations.get(r.id).activities
    end
  end

  describe "approve/2" do
    test "creates an active, verified account with the applied password" do
      r = verified()
      boss = admin()

      assert {:ok, %{is_approved: true, is_closed: true}} = CuratedRegistrations.approve(r, boss)

      assert {:ok, user} = Accounts.authenticate("newbie", "verysecret123")
      assert user.register_source == "cur_onboarding"
      assert user.email_verified_at
      refute Accounts.pending?(user)

      assert_enqueued(
        worker: SendEmail,
        args: %{"to" => "newbie@example.com", "subject" => "Your localhost Registration Update"}
      )

      assert {:error, :closed} = CuratedRegistrations.approve(Repo.reload!(r), boss)
    end

    test "refuses an unverified application" do
      assert {:error, :unverified} = CuratedRegistrations.approve(submitted(), admin())
    end
  end

  describe "reject/3" do
    test "closes the application and emails the note" do
      r = verified()

      assert {:ok, %{is_rejected: true, is_closed: true}} =
               CuratedRegistrations.reject(r, admin(), message: "Bots only, sorry.")

      [job] =
        all_enqueued(worker: SendEmail) |> Enum.filter(&(&1.args["text"] =~ "Bots only"))

      assert job.args["to"] == r.email
      assert Accounts.get_by_email(r.email) == nil
    end

    test "a silent rejection sends nothing" do
      r = verified()
      before = length(all_enqueued(worker: SendEmail))
      {:ok, _} = CuratedRegistrations.reject(r, admin(), notify: false)
      assert length(all_enqueued(worker: SendEmail)) == before
    end
  end
end
