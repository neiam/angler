defmodule Angler.Mailer.AppCodeEmail do
  @moduledoc """
  In-app registration verification email.

  Plain-text only — keeps spam-filter friction low and reads well in any client.
  """

  import Swoosh.Email

  @spec build(String.t(), String.t()) :: Swoosh.Email.t()
  def build(to, code) when is_binary(to) and is_binary(code) do
    from = Application.fetch_env!(:angler, :mail_from)

    new()
    |> to(to)
    |> from({Keyword.fetch!(from, :name), Keyword.fetch!(from, :address)})
    |> subject("Your Pixelfed verification code: #{code}")
    |> text_body("""
    Hi,

    Your Pixelfed verification code is:

        #{code}

    Enter this in the app to finish creating your account. The code expires
    in 24 hours.

    If you didn't request this, you can safely ignore this email — no account
    has been created.
    """)
  end
end
