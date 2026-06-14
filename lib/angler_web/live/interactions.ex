defmodule AnglerWeb.Live.Interactions do
  @moduledoc """
  Shared favourite/reblog toggling for the public LiveViews (feed + permalink).

  Takes the acting profile, a status id (string, from `phx-value-id`) and the
  interaction kind, applies the toggle, and returns the status re-rendered with
  the actor's viewer overlay so `favourited`/`reblogged` and the counters are
  fresh. Returns `:error` for anonymous users, bad ids, missing statuses, or an
  un-rebloggable target — callers treat that as a no-op.
  """

  alias Angler.Profiles.Profile
  alias Angler.Statuses
  alias Angler.Statuses.{Status, ViewerOverlay}
  alias AnglerWeb.MastodonAPI.Status, as: StatusJSON

  @type kind :: :favourite | :reblog

  @spec toggle(Profile.t() | nil, String.t(), kind()) :: {:ok, map()} | :error
  def toggle(%Profile{} = profile, id, kind) when kind in [:favourite, :reblog] do
    with {int_id, ""} <- Integer.parse(to_string(id)),
         %Status{} = status <- Statuses.get(int_id),
         overlay <- ViewerOverlay.for_status(profile.id, status.id),
         {:ok, updated} <- do_toggle(kind, profile, status, overlay) do
      {:ok, StatusJSON.render(updated, profile.id)}
    else
      _ -> :error
    end
  end

  def toggle(_, _, _), do: :error

  defp do_toggle(:favourite, p, s, %{favourited: true}), do: Statuses.unfavourite(p, s)
  defp do_toggle(:favourite, p, s, _), do: Statuses.favourite(p, s)
  defp do_toggle(:reblog, p, s, %{reblogged: true}), do: Statuses.unreblog(p, s)
  defp do_toggle(:reblog, p, s, _), do: Statuses.reblog(p, s)
end
