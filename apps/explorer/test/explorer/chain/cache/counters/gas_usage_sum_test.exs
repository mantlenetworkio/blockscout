defmodule Explorer.Chain.Cache.Counters.GasUsageSumTest do
  use Explorer.DataCase, async: false

  alias Explorer.Chain.Cache.Counters.{GasUsageSum, LastFetchedCounter}
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

  test "sums the gas used by the consensus blocks when the sum finishes in time" do
    insert(:block, gas_used: 21_000)
    insert(:block, gas_used: 50_000)
    # a block that lost consensus
    insert(:block, gas_used: 7, consensus: false)

    assert GasUsageSum.get_sum() == nil
    assert Decimal.equal?(wait_for_sum(), 71_000)
    assert Decimal.equal?(LastFetchedCounter.get("gas_usage_sum"), 71_000)
  end

  test "keeps the last stored sum when the sum runs past its timeout, and starts no new sum before the period ends" do
    LastFetchedCounter.upsert(%{counter_type: "gas_usage_sum", value: 42})
    :telemetry.attach("cancelled-sum", [:explorer, :repo, :query], &__MODULE__.report_cancel/4, self())
    on_exit(fn -> :telemetry.detach("cancelled-sum") end)
    # a query elsewhere holds the table past the timeout, as a long sum does on a live database (the test inserts no
    # block: its own sandbox transaction would hold a lock that keeps the other session waiting); an exact sum would
    # store 0
    release = ExternalConnection.hold_lock("blocks", "ACCESS EXCLUSIVE")

    assert GasUsageSum.get_sum() == nil
    assert_receive :query_canceled, 5_000
    # the cache period depends on the latest block number, which waits for this lock too
    release.()

    assert wait_for_sum() == 42
    wait_for_sum_task()

    # a read of the cached value starts no sum
    assert GasUsageSum.total() == 42
    assert ConCache.get(GasUsageSum.cache_name(), :async_task) == nil
  end

  # a query of the sum task that the test started (through the read) was cancelled
  def report_cancel(_event, _measurements, %{result: result}, test) do
    if test in Process.get(:"$callers", []) and
         match?({:error, %Postgrex.Error{postgres: %{code: :query_canceled}}}, result),
       do: send(test, :query_canceled)
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
