defmodule AnglerWeb.Honeypot do
  @moduledoc """
  Bot trap for the signup forms, mirroring upstream's Spatie honeypot
  (`config/honeypot.php`, `ProtectAgainstSpam` on `POST /register`).

  Two checks: a visually hidden text field with a randomized name that
  people never fill in, and a minimum time between showing the form and
  submitting it. Because the forms are LiveViews, the field name and the
  render time live in the socket instead of an encrypted `valid_from` input.

  A tripped check is meant to be answered as if the submission succeeded,
  so the bot learns nothing (upstream answers with a blank page).

      config :angler, :honeypot, enabled: true, seconds: 1
  """

  @enforce_keys [:field, :started_at]
  defstruct [:field, :started_at]

  @type t :: %__MODULE__{field: String.t(), started_at: integer()}

  @doc "Arm a honeypot for a freshly rendered form."
  @spec new() :: t()
  def new do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    %__MODULE__{
      field: config(:name, "my_name") <> "_" <> suffix,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @doc "Whether the submitted `params` look like a bot."
  @spec spam?(t(), map()) :: boolean()
  def spam?(%__MODULE__{} = hp, params) do
    enabled?() and (filled?(params[hp.field]) or too_fast?(hp))
  end

  @doc "Whether the honeypot is switched on (default true, as upstream)."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, true) == true

  defp filled?(value), do: is_binary(value) and value != ""

  defp too_fast?(%__MODULE__{started_at: started}) do
    System.monotonic_time(:millisecond) - started < config(:seconds, 1) * 1_000
  end

  defp config(key, default) do
    Keyword.get(Application.get_env(:angler, :honeypot, []), key, default)
  end
end
