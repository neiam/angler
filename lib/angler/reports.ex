defmodule Angler.Reports do
  @moduledoc """
  User reports — moderator inbox feed lives downstream. The Pixelfed mobile
  app fires `POST /api/v1.1/report` with `report_type`, `object_id`, and
  `object_type` set to "post" / "user" / "story". We don't yet support
  story reports.
  """

  import Ecto.Query, only: [from: 2]

  alias Angler.Accounts.User
  alias Angler.Profiles
  alias Angler.Profiles.Profile
  alias Angler.Reports.Report
  alias Angler.Repo
  alias Angler.Statuses

  @spec submit(User.t(), map()) :: {:ok, Report.t()} | {:error, atom()}
  def submit(%User{profile_id: reporter_pid} = user, %{} = attrs) do
    type = attrs["report_type"]
    object_id_str = attrs["object_id"]
    object_type = attrs["object_type"]

    cond do
      type not in Report.types() ->
        {:error, :invalid_type}

      object_type not in Report.object_types() ->
        {:error, :invalid_object_type}

      not is_binary(object_id_str) and not is_integer(object_id_str) ->
        {:error, :missing_object_id}

      object_type == "story" ->
        {:error, :unsupported_object_type}

      true ->
        with {:ok, object_id} <- parse_id(object_id_str),
             {:ok, reported_pid} <- resolve_target(object_type, object_id, reporter_pid) do
          if duplicate?(user.id, object_type, object_id) do
            {:error, :duplicate}
          else
            %{
              profile_id: reporter_pid,
              user_id: user.id,
              object_id: object_id,
              object_type: object_type,
              reported_profile_id: reported_pid,
              type: type
            }
            |> Report.changeset()
            |> Repo.insert()
            |> case do
              {:ok, report} -> {:ok, report}
              {:error, _} -> {:error, :invalid}
            end
          end
        end
    end
  end

  defp duplicate?(user_id, object_type, object_id) do
    Repo.exists?(
      from r in Report,
        where:
          r.user_id == ^user_id and r.object_type == ^object_type and
            r.object_id == ^object_id
    )
  end

  defp parse_id(n) when is_integer(n), do: {:ok, n}

  defp parse_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_object_id}
    end
  end

  defp resolve_target("post", id, reporter_pid) do
    case Statuses.get(id) do
      nil ->
        {:error, :invalid_object_id}

      %_{profile_id: ^reporter_pid} ->
        {:error, :self_report}

      %_{profile_id: pid} ->
        {:ok, pid}
    end
  end

  defp resolve_target("user", id, reporter_pid) when id == reporter_pid do
    {:error, :self_report}
  end

  defp resolve_target("user", id, _reporter_pid) do
    case Profiles.get_profile(id) do
      %Profile{id: pid} -> {:ok, pid}
      _ -> {:error, :invalid_object_id}
    end
  end
end
