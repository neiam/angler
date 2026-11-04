defmodule Angler.Auth.Username do
  @moduledoc """
  Username validation rules ported from
  `App\Http\Controllers\AppRegisterController#validateUsernameRule`.
  """

  alias Angler.Auth.RestrictedNames

  @doc """
  Validate the format of a username.

  Returns `:ok` or `{:error, message}`.
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  # One flat rule per upstream check, in upstream's order; splitting it would
  # only hide the list.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(name) when is_binary(name) do
    cond do
      String.length(name) < 2 or String.length(name) > 30 ->
        {:error, "Username is invalid. Must be 2-30 characters."}

      String.ends_with?(name, [".php", ".js", ".css"]) ->
        {:error, "Username is invalid."}

      not Regex.match?(~r/^[A-Za-z0-9]/u, name) ->
        {:error, "Username is invalid. Must start with a letter or number."}

      not Regex.match?(~r/[A-Za-z0-9]$/u, name) ->
        {:error, "Username is invalid. Must end with a letter or number."}

      special_count(name) > 1 ->
        {:error,
         "Username is invalid. Can only contain one dash (-), period (.) or underscore (_)."}

      not alnum_with_specials?(name) ->
        {:error,
         "Username is invalid. Username must be alpha-numeric and may contain dashes (-), periods (.) and underscores (_)."}

      not Regex.match?(~r/[A-Za-z]/u, name) ->
        {:error, "Username is invalid. Must contain at least one alphabetical character."}

      RestrictedNames.restricted?(name) ->
        {:error, "Username cannot be used."}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, "Username is required."}

  defp special_count(name) do
    String.graphemes(name)
    |> Enum.count(&(&1 in ["-", "_", "."]))
  end

  defp alnum_with_specials?(name) do
    name
    |> String.replace(["-", "_", "."], "")
    |> then(&Regex.match?(~r/^[A-Za-z0-9]+$/u, &1))
  end
end
