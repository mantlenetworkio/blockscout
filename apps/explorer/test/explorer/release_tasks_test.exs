defmodule Explorer.ReleaseTasksTest do
  use Explorer.DataCase, async: false

  alias Explorer.{ExternalConnection, ReleaseTasks}

  setup do
    config = Application.get_env(:explorer, ReleaseTasks)
    table = "release_tasks_test_#{System.unique_integer([:positive])}"
    admin = ExternalConnection.start()
    Postgrex.query!(admin, "CREATE TABLE #{table} (id integer)", [])

    on_exit(fn ->
      Application.put_env(:explorer, ReleaseTasks, config)
      {:ok, conn} = Postgrex.start_link(ExternalConnection.options())
      Postgrex.query!(conn, "DROP TABLE IF EXISTS #{table}", [])
      GenServer.stop(conn)
    end)

    %{table: table}
  end

  describe "bound_migration_session/1" do
    test "makes a migration give up a lock it cannot take within lock_timeout, instead of waiting", %{table: table} do
      Application.put_env(:explorer, ReleaseTasks, lock_timeout: 200, statement_timeout: 10_000)
      # a long-running query holds the table, as on a live database during a deploy
      ExternalConnection.hold_lock(table, "ACCESS SHARE")
      migration = ExternalConnection.start(after_connect: &ReleaseTasks.bound_migration_session/1)

      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               Postgrex.query(migration, "ALTER TABLE #{table} ADD COLUMN extra integer", [])
    end

    test "lets a statement run past lock_timeout once it does not wait for a lock" do
      Application.put_env(:explorer, ReleaseTasks, lock_timeout: 100, statement_timeout: nil)
      migration = ExternalConnection.start(after_connect: &ReleaseTasks.bound_migration_session/1)

      assert {:ok, _} = Postgrex.query(migration, "SELECT pg_sleep(1)", [])
    end

    test "cancels a migration statement that runs longer than statement_timeout" do
      Application.put_env(:explorer, ReleaseTasks, lock_timeout: 10_000, statement_timeout: 200)
      migration = ExternalConnection.start(after_connect: &ReleaseTasks.bound_migration_session/1)

      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
               Postgrex.query(migration, "SELECT pg_sleep(2)", [])
    end

    test "leaves a setting without a value at the database default" do
      Application.put_env(:explorer, ReleaseTasks, lock_timeout: nil, statement_timeout: nil)
      migration = ExternalConnection.start(after_connect: &ReleaseTasks.bound_migration_session/1)

      assert %{rows: [["0"]]} = Postgrex.query!(migration, "SHOW lock_timeout", [])
      assert %{rows: [["0"]]} = Postgrex.query!(migration, "SHOW statement_timeout", [])
    end
  end
end
