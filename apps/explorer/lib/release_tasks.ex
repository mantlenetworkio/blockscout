# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.ReleaseTasks do
  @moduledoc """
  Release tasks used to migrate or generate seeds.
  """

  alias Ecto.Migrator

  @start_apps [
    :crypto,
    :ssl,
    :postgrex,
    :ecto,
    # If using Ecto 3.0 or higher
    :ecto_sql
  ]

  def repos do
    Application.get_env(:explorer, :ecto_repos)
  end

  def create_and_migrate do
    start_services()

    create()
    run_migrations()

    stop_services()
  end

  def create do
    Enum.each(repos(), &create_db_for/1)
  end

  def migrate(_argv) do
    start_services()

    run_migrations()

    stop_services()
  end

  def seed(_argv) do
    start_services()

    run_migrations()

    run_seeds()

    stop_services()
  end

  defp start_services do
    IO.puts("Starting dependencies..")
    # Start apps necessary for executing migrations
    Enum.each(@start_apps, &Application.ensure_all_started/1)

    # Start the Repo(s) for app
    IO.puts("Starting repos..")

    # Switch pool_size to 2 for ecto > 3.0
    Enum.each(repos(), fn repo -> repo.start_link(pool_size: 2, after_connect: &bound_migration_session/1) end)
  end

  @doc """
    Bounds how long a migration on this connection may wait for a lock, and optionally how long a statement may run:
    Postgres `lock_timeout` and `statement_timeout`, set with DATABASE_MIGRATION_LOCK_TIMEOUT (10s by default) and
    DATABASE_MIGRATION_STATEMENT_TIMEOUT (unset by default). 0 turns a timeout off.

    Without a lock timeout a migration queued behind a long-running query waits as long as that query runs, and while
    it waits for its lock every new query on the table queues behind it. A startup probe then kills the container
    mid-migration, while the database keeps the abandoned session waiting with its locks, which blocks the next
    attempt. With it the migration fails, is rolled back, and the next start tries again. The lock timeout bounds only
    the wait: once a migration holds its locks, it runs for as long as its work takes.

    A statement timeout below a startup probe's budget lets the database, not the probe, end a statement that runs too
    long. Without a probe a long migration is better left to finish, so there is none by default.
  """
  @spec bound_migration_session(DBConnection.conn()) :: :ok
  def bound_migration_session(conn) do
    config = Application.get_env(:explorer, __MODULE__, [])

    for setting <- [:lock_timeout, :statement_timeout], milliseconds = config[setting], is_integer(milliseconds) do
      Postgrex.query!(conn, "SELECT set_config($1, $2, false)", [
        Atom.to_string(setting),
        Integer.to_string(milliseconds)
      ])
    end

    :ok
  end

  defp stop_services do
    IO.puts("Success!")
    :init.stop()
  end

  defp create_db_for(repo) do
    IO.puts("Create #{inspect(repo)} database if it doesn't exist")

    case repo.__adapter__.storage_up(repo.config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, term} -> {:error, term}
    end
  end

  defp run_migrations do
    Enum.each(repos(), &run_migrations_for/1)
  end

  defp run_migrations_for(repo) do
    app = Keyword.get(repo.config, :otp_app)
    IO.puts("Running migrations for #{app}")
    migrations_path = priv_path_for(repo, "migrations")
    Migrator.run(repo, migrations_path, :up, all: true)
  end

  defp run_seeds do
    Enum.each(repos(), &run_seeds_for/1)
  end

  # sobelow_skip ["RCE.CodeModule"]
  defp run_seeds_for(repo) do
    # Run the seed script if it exists
    seed_script = priv_path_for(repo, "seeds.exs")

    if File.exists?(seed_script) do
      IO.puts("Running seed script..")
      Code.eval_file(seed_script)
    end
  end

  defp priv_path_for(repo, filename) do
    app = Keyword.get(repo.config, :otp_app)

    repo_underscore =
      repo
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    priv_dir = "#{:code.priv_dir(app)}"

    Path.join([priv_dir, repo_underscore, filename])
  end
end
