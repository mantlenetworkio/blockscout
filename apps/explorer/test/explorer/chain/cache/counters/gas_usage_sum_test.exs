defmodule Explorer.Chain.Cache.Counters.GasUsageSumTest do
  use Explorer.DataCase, async: false

  alias Explorer.Chain.Cache.Counters.{GasUsageSum, LastFetchedCounter}
  alias Explorer.Chain.Transaction
  alias Explorer.ExternalConnection

  setup do
    config = Application.get_env(:explorer, GasUsageSum)
    Application.put_env(:explorer, GasUsageSum, Keyword.merge(config || [], enabled: true, query_timeout: 200))
    Supervisor.terminate_child(Explorer.Supervisor, GasUsageSum.child_id())
    Supervisor.restart_child(Explorer.Supervisor, GasUsageSum.child_id())

    on_exit(fn ->
      Application.put_env(:explorer, GasUsageSum, config)
      Supervisor.terminate_child(Explorer.Supervisor, GasUsageSum.child_id())
    end)
  end

  test "sums the gas used by all transactions when the sum finishes in time" do
    :transaction |> insert() |> with_block()
    :transaction |> insert() |> with_block()
    expected = Repo.one!(from(t in Transaction, select: sum(t.gas_used)))

    assert GasUsageSum.get_sum() == nil
    assert Decimal.equal?(wait_for_sum(), expected)
    assert Decimal.equal?(LastFetchedCounter.get("gas_usage_sum"), expected)
  end

  test "keeps the last stored sum when the sum runs past its timeout, and starts no new sum before the period ends" do
    LastFetchedCounter.upsert(%{counter_type: "gas_usage_sum", value: 42})
    # a query elsewhere holds the table past the timeout, as a long count does on a live database (the test inserts
    # no transaction: its own sandbox transaction would hold a lock that keeps the other session waiting); an exact
    # sum would store 0
    ExternalConnection.hold_lock("transactions", "ACCESS EXCLUSIVE")

    assert GasUsageSum.get_sum() == nil
    assert wait_for_sum() == 42
    wait_for_sum_task()

    # a read of the cached value starts no sum
    assert GasUsageSum.total() == 42
    assert ConCache.get(GasUsageSum.cache_name(), :async_task) == nil
  end

  # the sum task publishes the value before it clears its own slot
  defp wait_for_sum_task(attempts \\ 50) do
    case ConCache.get(GasUsageSum.cache_name(), :async_task) do
      nil ->
        :ok

      _task when attempts > 0 ->
        Process.sleep(100)
        wait_for_sum_task(attempts - 1)
    end
  end

  defp wait_for_sum(attempts \\ 50) do
    case ConCache.get(GasUsageSum.cache_name(), :sum) do
      nil when attempts > 0 ->
        Process.sleep(100)
        wait_for_sum(attempts - 1)

      value ->
        value
    end
  end
end
