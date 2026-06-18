defmodule Angler.Export.PostExport do
  @moduledoc """
  ActivityPub/JSON serialization of a profile's own posts, reusing the
  federation `NoteBuilder` so an export is byte-compatible with what we publish.

  Used by `Angler.Export.AccountArchive` (bundled into the `.zip`) and by the
  standalone "download my posts as JSON" endpoint.
  """

  alias Angler.Federation.NoteBuilder
  alias Angler.Profiles.Profile
  alias Angler.Statuses
  alias Angler.Statuses.Status

  @doc "The standalone AP `Note` object for a status."
  @spec note(Status.t(), Profile.t()) :: map()
  def note(%Status{} = status, %Profile{} = profile), do: NoteBuilder.object(status, profile)

  @doc "The AP `Create` activity wrapping the note."
  @spec create_activity(Status.t(), Profile.t()) :: map()
  def create_activity(%Status{} = status, %Profile{} = profile),
    do: NoteBuilder.create_activity(status, profile)

  @doc "All of `profile`'s posts as AP `Note` objects, oldest first."
  @spec notes_for(Profile.t()) :: [map()]
  def notes_for(%Profile{} = profile) do
    profile.id
    |> Statuses.list_for_export()
    |> Enum.map(&note(&1, profile))
  end
end
