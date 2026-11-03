defmodule Angler.Statuses.Status do
  @moduledoc """
  A post — text, photo, photo album, video, reply, or reblog.

  Local statuses have `local: true`, no `uri` (computed), and federate via
  outbound delivery. Remote statuses have `local: false` and store the AS2
  `id` in `uri`.

  See plans/statuses/models/status.md.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "statuses" do
    belongs_to :profile, Angler.Profiles.Profile

    field :caption, :string
    field :rendered, :string
    field :is_nsfw, :boolean, default: false
    field :cw_summary, :string

    field :visibility, Ecto.Enum, values: [:public, :unlisted, :private, :direct]
    field :scope, :string
    field :type, :string
    field :pf_type, :string

    field :local, :boolean, default: true
    field :uri, :string
    field :url, :string

    field :in_reply_to_id, :integer
    field :in_reply_to_profile_id, :integer
    # A remote reply's `inReplyTo`, set even when the parent isn't stored.
    field :in_reply_to_uri, :string
    field :reblog_of_id, :integer

    field :language, :string, default: "en"
    field :comments_disabled, :boolean, default: false
    # FEP-044f canQuote override (`Angler.Quotes`); nil = account default.
    field :quote_policy, :integer

    field :reply_count, :integer, default: 0
    field :reblogs_count, :integer, default: 0
    field :likes_count, :integer, default: 0

    field :edited_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    field :scheduled_at, :utc_datetime_usec
    field :place_id, :id
    field :group_id, :id
    # The story a story reply / reaction DM answers (`Angler.Stories.Federation`).
    field :story_id, :integer

    has_many :mentions, Angler.Statuses.Mention
    has_many :status_hashtags, Angler.Statuses.StatusHashtag
    has_many :media_attachments, Angler.Media.Asset, foreign_key: :status_id

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(
    id
    profile_id caption rendered is_nsfw cw_summary visibility scope type pf_type
    local uri url
    in_reply_to_id in_reply_to_profile_id in_reply_to_uri reblog_of_id
    language comments_disabled quote_policy
    reply_count reblogs_count likes_count
    edited_at deleted_at scheduled_at
    place_id group_id story_id
  )a

  @doc """
  Whether `status` answers another post, including a remote reply whose
  parent we never stored.
  """
  @spec reply?(%__MODULE__{}) :: boolean()
  def reply?(%__MODULE__{in_reply_to_id: id, in_reply_to_uri: uri}),
    do: not is_nil(id) or not is_nil(uri)

  @doc false
  def changeset(status \\ %__MODULE__{}, attrs) do
    status
    |> maybe_assign_id()
    |> cast(attrs, @cast_fields)
    |> validate_required([:profile_id, :visibility])
    |> unique_constraint(:uri)
  end

  defp maybe_assign_id(%__MODULE__{id: nil} = s), do: %{s | id: Angler.Snowflake.next()}
  defp maybe_assign_id(s), do: s
end
