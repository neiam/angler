defmodule Angler.Repo.Migrations.CuratedTemplatesAndRegistrationSettings do
  @moduledoc """
  * `curated_register_templates` — canned replies for curated-registration
    review (upstream curated_register_templates).
  * `instance_settings.captcha` / `.curated_registration` — admin overrides
    for the env config of the same name; NULL means "use the environment".
  """

  use Ecto.Migration

  def change do
    create table(:curated_register_templates) do
      add :name, :string, size: 30, null: false
      add :description, :text
      add :content, :text, null: false
      add :is_active, :boolean, null: false, default: false
      add :order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:instance_settings) do
      add :captcha, :map
      add :curated_registration, :map
    end
  end
end
