defmodule Angler.Repo.Migrations.RetypeMixedMediaStatuses do
  use Ecto.Migration

  # Remote posts mixing photos and videos used to be stored as "text", which
  # the photo-and-video-only feeds now drop. Upstream calls them
  # "photo:video:album".
  def up do
    execute("""
    UPDATE statuses s
    SET type = 'photo:video:album', pf_type = 'photo:video:album'
    WHERE s.type = 'text'
      AND EXISTS (SELECT 1 FROM media m WHERE m.status_id = s.id AND m.media_type LIKE 'image/%')
      AND EXISTS (SELECT 1 FROM media m WHERE m.status_id = s.id AND m.media_type LIKE 'video/%')
    """)
  end

  def down, do: :ok
end
