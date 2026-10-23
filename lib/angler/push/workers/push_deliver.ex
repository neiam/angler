defmodule Angler.Push.Workers.PushDeliver do
  @moduledoc """
  Send a single WebPush envelope to one subscription's endpoint.

  Hooked from `Angler.Notifications.notify/1`: after a fresh notification
  inserts, we fan out one job per push subscription bound to a token of the
  recipient. The worker filters by the subscription's `alerts` map (so
  `mention` events skip subscribers who only enabled `favourite`).

  410 Gone responses delete the subscription row — the device/browser
  uninstalled the SW or rotated the token.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: 60, fields: [:args], keys: [:notification_id, :subscription_id]]

  require Logger

  alias Angler.Notifications.Notification
  alias Angler.OAuth.Token
  alias Angler.Push.{Payload, Subscription, Vapid}
  alias Angler.Repo

  @doc """
  Enqueue one delivery job per subscription that should receive
  `notification_id`.

  Picks subscriptions whose `token.profile_id` matches the notification's
  `recipient_id`, whose `alerts[type]` is true, and whose `policy` permits
  the actor.
  """
  @spec fan_out(integer()) :: :ok
  def fan_out(notification_id) when is_integer(notification_id) do
    if Vapid.enabled?() do
      enqueue_jobs(notification_id)
    end

    :ok
  end

  defp enqueue_jobs(notification_id) do
    case Repo.get(Notification, notification_id) do
      nil ->
        :ok

      %Notification{} = n ->
        subs = subscriptions_for(n)

        Enum.each(subs, fn %Subscription{} = sub ->
          if alerts_match?(sub, n) and policy_match?(sub, n) do
            %{"notification_id" => notification_id, "subscription_id" => sub.id}
            |> __MODULE__.new()
            |> Oban.insert()
          end
        end)

        :ok
    end
  end

  defp subscriptions_for(%Notification{recipient_id: recipient_id}) do
    import Ecto.Query

    Repo.all(
      from s in Subscription,
        join: t in Token,
        on: t.id == s.token_id and is_nil(t.revoked_at) and t.profile_id == ^recipient_id,
        select: s
    )
  end

  defp alerts_match?(%Subscription{alerts: alerts}, %Notification{type: type}) do
    Map.get(alerts, type, false) == true
  end

  defp policy_match?(%Subscription{policy: "all"}, _), do: true
  defp policy_match?(%Subscription{policy: "none"}, _), do: false

  defp policy_match?(%Subscription{policy: "followed"}, %Notification{
         recipient_id: recipient_id,
         account_id: account_id
       }) do
    import Ecto.Query

    Repo.exists?(
      from f in Angler.Follows.Follower,
        where:
          f.profile_id == ^account_id and f.following_id == ^recipient_id and
            not is_nil(f.accepted_at)
    )
  end

  defp policy_match?(%Subscription{policy: "follower"}, %Notification{
         recipient_id: recipient_id,
         account_id: account_id
       }) do
    import Ecto.Query

    Repo.exists?(
      from f in Angler.Follows.Follower,
        where:
          f.profile_id == ^recipient_id and f.following_id == ^account_id and
            not is_nil(f.accepted_at)
    )
  end

  defp policy_match?(_, _), do: true

  ## Job-level

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"notification_id" => nid, "subscription_id" => sid}
      }) do
    case {Repo.get(Notification, nid), Repo.get(Subscription, sid)} do
      {nil, _} ->
        :ok

      {_, nil} ->
        :ok

      {%Notification{} = n, %Subscription{} = sub} ->
        deliver(n, sub)
    end
  end

  defp deliver(%Notification{} = notification, %Subscription{} = sub) do
    token = Repo.get!(Token, sub.token_id)
    payload = Payload.build(notification, nil) |> raw_token_for_token(token)

    body = Jason.encode!(payload)

    web_sub = %{
      endpoint: sub.endpoint,
      keys: %{p256dh: sub.p256dh, auth: sub.auth}
    }

    case sender().send(body, web_sub) do
      {:ok, %{status_code: code}} when code in 200..299 ->
        :ok

      {:ok, %{status_code: 410}} ->
        Repo.delete(sub)
        :ok

      {:ok, %{status_code: 404}} ->
        Repo.delete(sub)
        :ok

      {:ok, %{status_code: code}} ->
        Logger.warning("PushDeliver: remote #{code} for sub=#{sub.id}")
        {:error, "remote #{code}"}

      {:error, reason} ->
        Logger.warning("PushDeliver: error #{inspect(reason)} for sub=#{sub.id}")
        {:error, reason}
    end
  end

  # We don't actually round-trip the access_token plaintext — we only keep
  # the hash. Mastodon clients tolerate `access_token: nil` (the bearer
  # they'll use to fetch the notification is already in their keychain).
  defp raw_token_for_token(payload, _token), do: payload

  defp sender do
    Application.get_env(:angler, :push_sender, Angler.Push.Sender.WebPush)
  end
end
