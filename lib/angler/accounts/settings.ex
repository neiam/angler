defmodule Angler.Accounts.Settings do
  @moduledoc """
  Read/write helpers around `Angler.Accounts.UserSettings`.
  """

  alias Angler.Accounts.UserSettings
  alias Angler.Repo

  @web_allowed_fields ~w(enable_reblogs hide_reblog_banner)

  @doc "Allowed `web/settings` field names (Pixelfed allowlist)."
  def web_allowed_fields, do: @web_allowed_fields

  @spec get(integer()) :: UserSettings.t()
  def get(user_id) when is_integer(user_id) do
    case Repo.get_by(UserSettings, user_id: user_id) do
      nil ->
        {:ok, row} =
          %UserSettings{} |> UserSettings.changeset(%{user_id: user_id}) |> Repo.insert()

        row

      row ->
        row
    end
  end

  @spec set_web_field(integer(), String.t(), term()) ::
          {:ok, UserSettings.t()} | {:error, :unknown_field}
  def set_web_field(user_id, field, value) when is_binary(field) do
    if field in @web_allowed_fields do
      row = get(user_id)
      web = Map.put(row.web || %{}, field, value)

      row
      |> UserSettings.changeset(%{web: web})
      |> Repo.update()
    else
      {:error, :unknown_field}
    end
  end

  @spec set_app(integer(), map()) :: {:ok, UserSettings.t()}
  def set_app(user_id, common) when is_map(common) do
    row = get(user_id)
    row |> UserSettings.changeset(%{app: common}) |> Repo.update()
  end
end
