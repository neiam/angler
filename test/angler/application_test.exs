defmodule Angler.ApplicationTest do
  use ExUnit.Case, async: false

  describe "migrator_children/0" do
    test "is empty by default (dev/test never auto-migrate)" do
      # :auto_migrate is unset outside prod.
      assert Angler.Application.migrator_children() == []
    end

    test "adds the Ecto.Migrator child when :auto_migrate is on" do
      Application.put_env(:angler, :auto_migrate, true)
      on_exit(fn -> Application.delete_env(:angler, :auto_migrate) end)

      assert [{Ecto.Migrator, repos: [Angler.Repo]}] = Angler.Application.migrator_children()
    end
  end
end
