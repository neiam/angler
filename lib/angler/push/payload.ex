defmodule Angler.Push.Payload do
  @moduledoc """
  Build the JSON payload Mastodon-shape clients expect on a push event.

  Mastodon's push payload (as documented in Element/Tusky/Pixelfed sources):

      {
        "access_token": "<bearer of the subscription's token>",
        "preferred_locale": "en",
        "notification_id": <integer>,
        "notification_type": "favourite|reblog|follow|mention|...",
        "icon": "<url>",
        "title": "Bob favourited your post",
        "body": "<text excerpt>"
      }
  """

  alias Angler.Notifications.Notification
  alias Angler.Profiles.Profile

  @spec build(Notification.t(), String.t() | nil) :: map()
  def build(%Notification{} = n, access_token \\ nil) do
    n = Angler.Repo.preload(n, [:account, status: :profile])

    %{
      "access_token" => access_token,
      "preferred_locale" => "en",
      "notification_id" => n.id,
      "notification_type" => n.type,
      "icon" => avatar_for(n.account),
      "title" => title_for(n),
      "body" => body_for(n)
    }
  end

  defp title_for(%Notification{type: "favourite", account: %Profile{} = a}),
    do: "#{display_name(a)} favourited your post"

  defp title_for(%Notification{type: "reblog", account: %Profile{} = a}),
    do: "#{display_name(a)} boosted your post"

  defp title_for(%Notification{type: "follow", account: %Profile{} = a}),
    do: "#{display_name(a)} followed you"

  defp title_for(%Notification{type: "follow_request", account: %Profile{} = a}),
    do: "#{display_name(a)} requested to follow you"

  defp title_for(%Notification{type: "mention", account: %Profile{} = a}),
    do: "#{display_name(a)} mentioned you"

  defp title_for(%Notification{type: type, account: %Profile{} = a}),
    do: "#{display_name(a)}: #{type}"

  defp title_for(%Notification{type: type}), do: type

  defp body_for(%Notification{status: %{caption: c}}) when is_binary(c) and c != "" do
    c |> String.trim() |> truncate(160)
  end

  defp body_for(_), do: ""

  defp display_name(%Profile{name: n}) when is_binary(n) and n != "", do: n
  defp display_name(%Profile{username: u}), do: "@" <> u

  defp avatar_for(%Profile{avatar_path: p}) when is_binary(p), do: p
  defp avatar_for(_), do: nil

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: binary_part(s, 0, max - 1) <> "…"
end
