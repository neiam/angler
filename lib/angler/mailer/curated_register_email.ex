defmodule Angler.Mailer.CuratedRegisterEmail do
  @moduledoc """
  Plain-text emails for curated registration, one per upstream mailable
  (`App\\Mail\\CuratedRegister*`): confirm the applicant's email, tell them
  they were accepted or rejected, ask them for more details, and notify
  admins of a new verified application or an applicant's reply.

  Each builder returns `{subject, text}`; `Angler.CuratedRegistrations.Workers.SendEmail`
  wraps it in a `Swoosh.Email`.
  """

  alias Angler.CuratedRegistrations.CuratedRegister

  @footer """

  --
  This is an automated message, replies to this email aren't monitored.
  """

  @spec build(String.t(), String.t(), String.t()) :: Swoosh.Email.t()
  def build(to, subject, text) do
    from = Application.fetch_env!(:angler, :mail_from)

    Swoosh.Email.new()
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({Keyword.fetch!(from, :name), Keyword.fetch!(from, :address)})
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.text_body(text)
  end

  def confirm_email(%CuratedRegister{} = r, url) do
    {"Welcome to Pixelfed! Please Confirm Your Email",
     """
     Hello @#{r.username},

     Thanks for applying to join #{host()}. Please confirm your email address
     so we can review your application:

         #{url}

     The link expires in 7 days. If you didn't apply, you can ignore this email.
     """ <> @footer}
  end

  def accepted(%CuratedRegister{} = r) do
    {"Your #{host()} Registration Update",
     """
     Hello @#{r.username},

     Good news: your application was approved and your account is active.
     Sign in here:

         #{base()}/login

     Welcome aboard!
     """ <> @footer}
  end

  def rejected(%CuratedRegister{} = r, message) do
    note =
      if is_binary(message) and String.trim(message) != "",
        do: "\nA note from the admin team:\n\n#{message}\n",
        else: ""

    {"Your #{host()} Registration Update",
     """
     Hello @#{r.username},

     We appreciate the time you took to apply for an account on #{host()}.
     Unfortunately, after reviewing your application, we have decided not to
     proceed with activating your account.
     #{note}
     If you believe this decision was made in error, please contact us.
     """ <> @footer}
  end

  def request_details(%CuratedRegister{} = r, message, url) do
    {"[Action Needed]: Additional information requested",
     """
     Hello @#{r.username},

     An admin reviewing your application to #{host()} needs a little more
     information:

     #{message}

     Reply here:

         #{url}
     """ <> @footer}
  end

  def admin_new_application(%CuratedRegister{} = r) do
    {"[Requires Action]: New Curated Onboarding Application",
     """
     A new application (@#{r.username}, #{r.email}) has verified its email and
     is waiting for review:

         #{review_url(r)}
     """ <> @footer}
  end

  def admin_user_response(%CuratedRegister{} = r) do
    {"Curated Register Notify Admin User Response",
     """
     @#{r.username} replied to your request for more details:

         #{review_url(r)}
     """ <> @footer}
  end

  defp review_url(r), do: "#{base()}/admin/curated-onboarding/#{r.id}"
  defp base, do: AnglerWeb.Endpoint.url()
  defp host, do: URI.parse(base()).host
end
