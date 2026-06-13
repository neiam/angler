defmodule Angler.Mailer.PasswordResetEmail do
  @moduledoc """
  Password-reset email carrying a one-time magic link.

  Plain-text only — keeps spam-filter friction low and reads well in any client.
  """

  import Swoosh.Email

  @spec build(String.t(), String.t()) :: Swoosh.Email.t()
  def build(to, url) when is_binary(to) and is_binary(url) do
    from = Application.fetch_env!(:angler, :mail_from)

    new()
    |> to(to)
    |> from({Keyword.fetch!(from, :name), Keyword.fetch!(from, :address)})
    |> subject("Reset your Pixelfed password")
    |> text_body("""
    Hi,

    We received a request to reset your password. Open the link below to choose
    a new one:

        #{url}

    The link expires in 1 hour. If you didn't request this, you can safely
    ignore this email — your password won't change.
    """)
  end
end
