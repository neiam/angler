defmodule Angler.Push do
  @moduledoc """
  WebPush subscription lifecycle. One subscription per OAuth access token —
  re-subscribing replaces the prior row in place.
  """

  import Ecto.Query, warn: false

  alias Angler.OAuth.Token
  alias Angler.Push.Subscription
  alias Angler.Repo

  @spec get(Token.t()) :: Subscription.t() | nil
  def get(%Token{id: token_id}), do: Repo.get_by(Subscription, token_id: token_id)

  @spec subscribe(Token.t(), map()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(%Token{id: token_id}, params) when is_map(params) do
    sub = params["subscription"] || %{}
    keys = sub["keys"] || %{}
    data = params["data"] || %{}
    alerts = data["alerts"] || %{}

    attrs = %{
      token_id: token_id,
      endpoint: sub["endpoint"],
      p256dh: keys["p256dh"],
      auth: keys["auth"],
      alerts: normalize_alerts(alerts),
      policy: data["policy"] || "all"
    }

    case Repo.get_by(Subscription, token_id: token_id) do
      nil -> %Subscription{} |> Subscription.changeset(attrs) |> Repo.insert()
      existing -> existing |> Subscription.changeset(attrs) |> Repo.update()
    end
  end

  @spec update_alerts(Token.t(), map()) ::
          {:ok, Subscription.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_alerts(%Token{} = token, params) do
    case get(token) do
      nil ->
        {:error, :not_found}

      sub ->
        data = params["data"] || %{}
        alerts = data["alerts"] || %{}

        sub
        |> Subscription.changeset(%{
          alerts: normalize_alerts(alerts),
          policy: data["policy"] || sub.policy
        })
        |> Repo.update()
    end
  end

  @spec unsubscribe(Token.t()) :: :ok
  def unsubscribe(%Token{id: token_id}) do
    {_, _} = from(s in Subscription, where: s.token_id == ^token_id) |> Repo.delete_all()
    :ok
  end

  defp normalize_alerts(alerts) when is_map(alerts) do
    Map.new(alerts, fn {k, v} -> {to_string(k), truthy?(v)} end)
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
