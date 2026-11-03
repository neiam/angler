defmodule Angler.Federation.Workers.RemoteAvatarFetch do
  @moduledoc """
  Download a remote profile's avatar or header and store a local copy, as
  upstream's `AvatarPipeline\\RemoteAvatarFetch` does (`REMOTE_AVATARS`, on
  by default).

  Until it runs, and if it fails, the profile shows the origin's URL. The
  bytes come through `Angler.Federation.HTTP.download/2` (SSRF guards, size
  cap), must sniff as an image, and are stored through `Angler.Media.upload/3`
  so they get the usual EXIF strip and resize. A job whose URL the profile no
  longer points at is dropped.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [period: 3600, fields: [:args], keys: [:profile_id, :kind, :url]]

  require Logger

  alias Angler.Federation.HTTP
  alias Angler.Media
  alias Angler.Media.Storage
  alias Angler.Profiles.Profile
  alias Angler.Repo
  alias Angler.Stories.RemoteMedia

  # Upstream max_avatar_size (2000 KB); headers get max_photo_size (15000 KB).
  @max_bytes %{"avatar" => 2_000 * 1024, "header" => 15_000 * 1024}
  @mimes ~w(image/jpeg image/png image/webp image/gif)
  @fields %{
    "avatar" => {:avatar_path, :avatar_remote_url},
    "header" => {:header_path, :header_remote_url}
  }

  @doc "Whether remote avatars and headers are stored locally."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:angler, :remote_avatars, true) == true

  @spec enqueue(integer(), String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id, kind, url) when kind in ["avatar", "header"] do
    %{"profile_id" => profile_id, "kind" => kind, "url" => url}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => id, "kind" => kind, "url" => url}}) do
    {path_field, source_field} = Map.fetch!(@fields, kind)

    with %Profile{} = profile <- Repo.get(Profile, id),
         ^url <- Map.get(profile, source_field),
         {:ok, stored_url} <- download(profile, kind, url) do
      profile |> Ecto.Changeset.change(%{path_field => stored_url}) |> Repo.update()
      :ok
    else
      {:error, reason} ->
        Logger.info("remote #{kind} for profile #{id} not stored: #{inspect(reason)}")
        # Bad bytes won't get better; a network failure might.
        if reason in [:invalid_image, :account_size_limit], do: :ok, else: {:error, reason}

      _ ->
        :ok
    end
  end

  defp download(profile, kind, url) do
    with {:ok, bytes} <- HTTP.download(url, max_bytes: @max_bytes[kind], accept: "image/*"),
         mime when mime in @mimes <- RemoteMedia.sniff(bytes) || {:error, :invalid_image} do
      tmp = Path.join(System.tmp_dir!(), "angler-#{kind}-" <> Ecto.UUID.generate())

      try do
        File.write!(tmp, bytes)

        upload = %Plug.Upload{path: tmp, content_type: mime, filename: kind}

        with {:ok, asset} <- Media.upload(profile, upload) do
          {:ok, Storage.url(asset, :original)}
        end
      after
        File.rm(tmp)
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_image}
    end
  end
end
