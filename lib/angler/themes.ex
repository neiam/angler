defmodule Angler.Themes do
  @moduledoc """
  Catalog of UI themes available to the web frontend.

  Names map 1:1 to the daisyUI theme plugin entries in `assets/css/app.css`.
  The same set is used by the sibling `waxx` and `diogramos` frontends.
  """

  @neiam ~w(her afterdark forest sky clays stones)
  @builtin ~w(light dark)
  @custom ~w(blueprint)

  @type theme :: String.t()

  @spec all() :: [theme()]
  def all, do: @builtin ++ @neiam ++ @custom

  @spec neiam() :: [theme()]
  def neiam, do: @neiam

  @spec default() :: theme()
  def default, do: "blueprint"

  @spec valid?(theme()) :: boolean()
  def valid?(theme) when is_binary(theme), do: theme in all() or theme == "system"
  def valid?(_), do: false
end
