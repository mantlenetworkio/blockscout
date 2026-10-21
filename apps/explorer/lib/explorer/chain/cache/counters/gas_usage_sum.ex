defmodule Explorer.Chain.Cache.Counters.GasUsageSum do
  @moduledoc """
  Cache for total gas usage.
  """
  require Logger

  import Ecto.Query,
    only: [
      from: 2
    ]

  use Explorer.Chain.MapCache,
    name: :gas_usage,
    key: :sum,
    key: :async_task,
    global_ttl: :infinity,
    ttl_check_interval: :timer.seconds(1),
    callback: &async_task_on_deletion(&1)

  alias Explorer.Chain.Block
  alias Explorer.Chain.Cache.Counters.Helper, as: CacheCountersHelper
  alias Explorer.Chain.Cache.Counters.LastFetchedCounter
  alias Explorer.Repo

  @cache_key "gas_usage_sum"

  @spec total() :: non_neg_integer()
  def total do
    cached_value_from_ets = __MODULE__.get_sum()

    CacheCountersHelper.evaluate_count(@cache_key, cached_value_from_ets)
  end

  defp handle_fallback(:sum) do
    # This will get the task PID if one exists, check if it's running and launch
    # a new task if task doesn't exist or it's not running.
    # See next `handle_fallback` definition
    safe_get_async_task()

    {:return, nil}
  end

  defp handle_fallback(:async_task) do
    if Application.get_env(:explorer, __MODULE__)[:enabled] do
      # If this gets called it means an async task was requested, but none exists
      # so a new one needs to be launched
      {:ok, task} =
        Task.start_link(fn ->
          try do
            update_sum()
          rescue
            e ->
              Logger.debug([
                "Couldn't update total gas used: ",
                Exception.format(:error, e, __STACKTRACE__)
              ])
          end

          set_async_task(nil)
        end)

      {:update, task}
    else
      {:update, nil}
    end
  end

  # By setting this as a `callback` an async task will be started each time the
  # `sum` expires (unless there is one already running)
  defp async_task_on_deletion({:delete, _, :sum}), do: safe_get_async_task()

  defp async_task_on_deletion(_data), do: nil

  # The sum reads the whole blocks table, which on a large chain takes minutes (CACHE_TOTAL_GAS_USAGE_QUERY_TIMEOUT
  # bounds it). Past the bound the last stored sum is cached for the period instead, so the next read does not start
  # another sum.
  defp update_sum do
    case CacheCountersHelper.with_statement_timeout(query_timeout(), &fetch_sum_gas_used/0) do
      {:ok, result} ->
        LastFetchedCounter.upsert(%{counter_type: @cache_key, value: result})
        set_sum(%ConCache.Item{ttl: ttl(), value: result})

      {:error, :timeout} ->
        Logger.warning(
          "Summing the gas used by the consensus blocks was cancelled, by its #{query_timeout()} ms timeout or by an " <>
            "operator; the last stored sum is served until the next sum."
        )

        set_sum(%ConCache.Item{ttl: ttl(), value: last_stored_sum()})
    end
  end

  defp last_stored_sum, do: @cache_key |> LastFetchedCounter.get() |> Decimal.to_integer()

  defp ttl, do: CacheCountersHelper.ttl(__MODULE__, "CACHE_TOTAL_GAS_USAGE_PERIOD")

  defp query_timeout do
    case Application.get_env(:explorer, __MODULE__)[:query_timeout] do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> :infinity
    end
  end

  # The total is the gas the consensus blocks used, as their headers report it: the gas used by their transactions,
  # read from one row per block instead of one per transaction. It runs ahead of the transactions' own sum while a
  # block's transactions are still being imported, and it leaves out the transactions of blocks that lost consensus.
  @spec fetch_sum_gas_used() :: non_neg_integer
  defp fetch_sum_gas_used do
    query =
      from(
        block in Block,
        where: block.consensus == true,
        select: sum(block.gas_used)
      )

    Repo.one!(query, timeout: :infinity) || 0
  end
end
