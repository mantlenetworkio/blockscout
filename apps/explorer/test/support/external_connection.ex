defmodule Explorer.ExternalConnection do
  @moduledoc """
  Database connections outside the test sandbox, whose locks other sessions really see.

  A test uses them to put its own sandboxed queries behind a lock or an old snapshot, the way a long-running query
  does on a live database.
  """

  alias Explorer.Repo

  @doc "The connection options of the test database, for a Postgrex connection outside the sandbox."
  @spec options(keyword()) :: keyword()
  def options(extra \\ []) do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password, :socket_dir, :ssl])
    |> Keyword.merge(pool_size: 1, backoff_type: :stop)
    |> Keyword.merge(extra)
  end

  @doc """
  Opens a connection outside the sandbox. It is stopped when the test exits.
  """
  @spec start(keyword()) :: pid()
  def start(extra \\ []) do
    {:ok, conn} = Postgrex.start_link(options(extra))
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)
    conn
  end

  @doc """
  Takes a `mode` lock on `table` in a transaction of its own. Returns, once the lock is held, a function that releases
  it; otherwise the test's exit does.
  """
  @spec hold_lock(String.t(), String.t()) :: (-> :ok)
  def hold_lock(table, mode) do
    parent = self()

    holder =
      spawn(fn ->
        {:ok, conn} = Postgrex.start_link(options())

        Postgrex.transaction(
          conn,
          fn transaction ->
            Postgrex.query!(transaction, "LOCK TABLE #{table} IN #{mode} MODE", [])
            send(parent, {:locked, self()})

            receive do
              :release -> Postgrex.rollback(transaction, :released)
            end
          end,
          timeout: :infinity
        )

        GenServer.stop(conn)
      end)

    release = fn -> release(holder) end
    # callbacks run in reverse order, so the lock is gone before the cleanup that a test registered earlier
    ExUnit.Callbacks.on_exit(release)

    receive do
      {:locked, ^holder} -> release
    after
      5_000 -> raise "could not lock #{table}"
    end
  end

  defp release(holder) do
    monitor = Process.monitor(holder)
    send(holder, :release)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      5_000 ->
        Process.exit(holder, :kill)
        :ok
    end
  end
end
