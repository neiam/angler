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

      true ->
        with {:ok, message} <- clean_message(attrs["message"]),
             {:ok, object_id} <- parse_id(object_id_str),
             {:ok, reported_pid} <- resolve_target(object_type, object_id, reporter_pid),
             :ok <- check_not_duplicate(user.id, object_type, object_id) do
          %{
            profile_id: reporter_pid,
            user_id: user.id,
            object_id: object_id,
            object_type: object_type,
            reported_profile_id: reported_pid,
            type: type,
            message: message
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

  defp check_not_duplicate(user_id, object_type, object_id) do
    if duplicate?(user_id, object_type, object_id), do: {:error, :duplicate}, else: :ok
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

  # Upstream's optional note from the reporter: tags stripped, at most 255.
  @max_message 255

  defp clean_message(nil), do: {:ok, nil}

  defp clean_message(m) when is_binary(m) do
    m = m |> String.replace(~r/<[^>]*>/, "") |> String.trim()

    cond do
      m == "" -> {:ok, nil}
      String.length(m) > @max_message -> {:error, :message_too_long}
      true -> {:ok, m}
    end
  end

  defp clean_message(_), do: {:error, :invalid}

  # A post (or DM) the reporter can't see doesn't exist as far as they know.
  defp resolve_target(type, id, reporter_pid) when type in ["post", "direct_message"] do
    case Statuses.get(id) do
      %_{profile_id: ^reporter_pid} ->
        {:error, :self_report}

      %_{visibility: v} = status when type == "post" or v == :direct ->
        if Statuses.visible_to?(status, reporter_pid),
          do: {:ok, status.profile_id},
          else: {:error, :invalid_object_id}

      _ ->
        {:error, :invalid_object_id}
    end
  end

  defp resolve_target("story", id, reporter_pid) do
    case Angler.Repo.get(Angler.Stories.Story, id) do
      %{profile_id: ^reporter_pid} -> {:error, :self_report}
      %{profile_id: pid} -> {:ok, pid}
      nil -> {:error, :invalid_object_id}
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
