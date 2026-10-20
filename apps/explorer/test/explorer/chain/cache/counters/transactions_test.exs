defmodule Explorer.Chain.Cache.Counters.TransactionsTest do
  use Explorer.DataCase
  alias Explorer.Chain.Cache.Counters.{Helper, LastFetchedCounter, TransactionsCount}
  alias Explorer.ExternalConnection

  setup do
    Supervisor.terminate_child(Explorer.Supervisor, TransactionsCount.child_id())
    Supervisor.restart_child(Explorer.Supervisor, TransactionsCount.child_id())
    on_exit(fn -> Supervisor.terminate_child(Explorer.Supervisor, TransactionsCount.child_id()) end)
    :ok
  end

  test "returns default transaction count" do
    result = TransactionsCount.get_count()

    assert is_nil(result)
  end

  test "updates cache if initial value is zero" do
    insert(:transaction)
    insert(:transaction)

    _result = TransactionsCount.get_count()

    Process.sleep(1000)

    updated_value = TransactionsCount.get_count()

    assert updated_value == 2
  end

  test "does not update cache if cache period did not pass" do
    insert(:transaction)
    insert(:transaction)

    _result = TransactionsCount.get_count()

    Process.sleep(1000)

    updated_value = TransactionsCount.get_count()

    assert updated_value == 2

    insert(:transaction)
    insert(:transaction)

    _updated_value = TransactionsCount.get_count()

    Process.sleep(1000)

    updated_value = TransactionsCount.get_count()

    assert updated_value == 2
  end

  test "returns 0 on empty table" do
    assert 0 == TransactionsCount.get()
  end

  describe "an exact count that runs past its timeout" do
    setup do
      config = Application.get_env(:explorer, TransactionsCount)
      Application.put_env(:explorer, TransactionsCount, Keyword.put(config, :query_timeout, 200))
      on_exit(fn -> Application.put_env(:explorer, TransactionsCount, config) end)
    end

    test "serves the table estimate before any exact count, and starts no new count before the cache period ends" do
      value = count_past_its_timeout()

      assert value == Helper.estimated_transactions_count()
      # an exact count would have been stored
      assert LastFetchedCounter.get("transactions_count", nullable: true) == nil

      # a read of the cached value starts no count
      assert TransactionsCount.get() == value
      assert ConCache.get(TransactionsCount.cache_name(), :async_task) == nil
    end

    test "serves the last exact count rather than the estimate, as a read does while a count runs" do
      LastFetchedCounter.upsert(%{counter_type: "transactions_count", value: 42})

      assert count_past_its_timeout() == 42
      assert TransactionsCount.get() == 42
    end
  end

  def report_cancel(_event, _measurements, %{result: result}, test) do
    if match?({:error, %Postgrex.Error{postgres: %{code: :query_canceled}}}, result), do: send(test, :query_canceled)
  end

  # Starts a count that a query elsewhere holds past the timeout, as a long count does on a live database, and returns
  # the value cached instead. The test inserts no transaction: its own sandbox transaction would hold a lock that keeps
  # the other session waiting.
  defp count_past_its_timeout do
    :telemetry.attach("cancelled-count", [:explorer, :repo, :query], &__MODULE__.report_cancel/4, self())
    on_exit(fn -> :telemetry.detach("cancelled-count") end)

    release = ExternalConnection.hold_lock("transactions", "ACCESS EXCLUSIVE")

    assert TransactionsCount.get_count() == nil
    assert_receive :query_canceled, 5_000
    # the estimate reads the table's size, which waits for this lock too
    release.()

    value = wait_for_count()
    wait_for_count_task()
    value
  end

  # the count task publishes the value before it clears its own slot
  defp wait_for_count_task(attempts \\ 50) do
    case ConCache.get(TransactionsCount.cache_name(), :async_task) do
      nil ->
        :ok

      _task when attempts > 0 ->
        Process.sleep(100)
        wait_for_count_task(attempts - 1)
    end
  end

  defp wait_for_count(attempts \\ 50) do
    case ConCache.get(TransactionsCount.cache_name(), :count) do
      nil when attempts > 0 ->
        Process.sleep(100)
        wait_for_count(attempts - 1)

      value ->
        value
    end
  end
end
