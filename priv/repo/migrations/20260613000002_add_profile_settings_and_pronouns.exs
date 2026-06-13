defmodule Angler.Repo.Migrations.AddProfileSettingsAndPronouns do
  use Ecto.Migration

  def change do
    # Display/privacy settings the Pixelfed app round-trips through the account
    # `settings` block (crawlable, public_dm, show_profile_*_count, etc.). The
    # ones without a dedicated profiles column live here.
    alter table(:user_settings) do
      add :account, :map, null: false, default: %{}
    end

    alter table(:profiles) do
      add :pronouns, {:array, :text}, null: false, default: []
    end
  end
end
