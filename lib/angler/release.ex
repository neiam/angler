defmodule Angler.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :angler

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Enable / bootstrap a user without Mix. Clears any blocking status (pending,
  disabled) and optionally grants roles.

      bin/angler eval 'Angler.Release.enable_user("alice")'
      bin/angler eval 'Angler.Release.enable_user("alice", admin: true)'

  Accepts a username or email. Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  def enable_user(handle, opts \\ []) when is_binary(handle) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Angler.Repo, fn _repo ->
        Angler.Accounts.enable_user(handle, opts)
      end)

    case result do
      {:ok, user} ->
        IO.puts("Enabled user ##{user.id} (#{user.email})" <> roles(user))

      {:error, :not_found} ->
        IO.puts("No user found for #{inspect(handle)}")
    end

    result
  end

  @doc """
  Grant or revoke admin without Mix.

      bin/angler eval 'Angler.Release.set_admin("alice")'
      bin/angler eval 'Angler.Release.set_admin("alice", false)'

  Accepts a username or email. Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  def set_admin(handle, value \\ true) when is_binary(handle) and is_boolean(value) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Angler.Repo, fn _repo ->
        Angler.Accounts.set_admin_by_handle(handle, value)
      end)

    case result do
      {:ok, user} ->
        IO.puts(
          "#{if value, do: "Granted", else: "Revoked"} admin for ##{user.id} (#{user.email})"
        )

      {:error, :not_found} ->
        IO.puts("No user found for #{inspect(handle)}")

      {:error, _} = err ->
        IO.puts("Failed: #{inspect(err)}")
    end

    result
  end

  defp roles(user) do
    [user.is_admin && "admin", user.is_moderator && "moderator"]
    |> Enum.filter(& &1)
    |> case do
      [] -> ""
      list -> " [" <> Enum.join(list, ", ") <> "]"
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
