defmodule Indexer.Fetcher.Optimism.OutputRoot do
  @moduledoc """
  Fills op_output_roots DB table.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  import EthereumJSONRPC, only: [json_rpc: 2, quantity_to_integer: 1]

  alias EthereumJSONRPC.Contract
  alias Explorer.Application.Constants
  alias Explorer.{Chain, Helper, Repo}
  alias Explorer.Chain.Optimism.{DisputeGame, OutputRoot}
  alias Indexer.Fetcher.Optimism
  alias Indexer.Helper, as: IndexerHelper
  alias Indexer.RollupReorgMonitorQueue

  @fetcher_name :optimism_output_roots
  @stop_constant_key "optimism_output_roots_stopped"
  @counter_type "optimism_output_roots_fetcher_last_l1_block_hash"
  @empty_hash "0x0000000000000000000000000000000000000000000000000000000000000000"

  # 32-byte signature of the event OutputProposed(bytes32 indexed outputRoot, uint256 indexed l2OutputIndex, uint256 indexed l2BlockNumber, uint256 l1Timestamp)
  @output_proposed_event "0xa7aaf2512769da4e444e3de247be2564225c2e7a8f74cfe528e46e17d24868e2"

  # 4-byte selectors of the L2OutputOracle `startingBlockNumber()` and `FINALIZATION_PERIOD_SECONDS()` public getters.
  @starting_block_number_selector "0x70872aa5"
  @finalization_period_selector "0xf4daa291"

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(_args) do
    {:ok, %{}, {:continue, :ok}}
  end

  @impl GenServer
  def handle_continue(:ok, _state) do
    Logger.metadata(fetcher: @fetcher_name)

    # two seconds pause needed to avoid exceeding Supervisor restart intensity when DB issues
    :timer.sleep(2000)

    if Constants.get_constant_value(@stop_constant_key) == "true" do
      Logger.warning("#{__MODULE__} will not start because dispute games exist.")
      {:stop, :normal, %{}}
    else
      env = Application.get_all_env(:indexer)[__MODULE__]
      Optimism.init_continue(env[:output_oracle], __MODULE__)
    end
  end

  @impl GenServer
  def handle_info(
        :continue,
        %{
          contract_address: output_oracle,
          block_check_interval: block_check_interval,
          start_block: start_block,
          end_block: end_block,
          json_rpc_named_arguments: json_rpc_named_arguments,
          eth_get_logs_range_size: eth_get_logs_range_size,
          stop: stop
        } = state
      ) do
    # credo:disable-for-next-line
    time_before = Timex.now()

    # Before the chunk loop: on a fresh start the loop can run for a long time while catching up.
    state =
      state
      |> maybe_store_starting_block_number()
      |> maybe_refresh_l1_heads()

    chunks_number = ceil((end_block - start_block + 1) / eth_get_logs_range_size)
    chunk_range = Range.new(0, max(chunks_number - 1, 0), 1)

    last_written_block =
      chunk_range
      |> Enum.reduce_while(start_block - 1, fn current_chunk, _ ->
        chunk_start = start_block + eth_get_logs_range_size * current_chunk
        chunk_end = min(chunk_start + eth_get_logs_range_size - 1, end_block)

        if chunk_end >= chunk_start do
          IndexerHelper.log_blocks_chunk_handling(chunk_start, chunk_end, start_block, end_block, nil, :L1)

          {:ok, result} =
            IndexerHelper.get_logs(
              chunk_start,
              chunk_end,
              output_oracle,
              [@output_proposed_event],
              json_rpc_named_arguments,
              0,
              IndexerHelper.infinite_retries_number()
            )

          output_roots = events_to_output_roots(result)

          {:ok, _} =
            Chain.import(%{
              optimism_output_roots: %{params: output_roots},
              timeout: :infinity
            })

          IndexerHelper.log_blocks_chunk_handling(
            chunk_start,
            chunk_end,
            start_block,
            end_block,
            "#{Enum.count(output_roots)} OutputProposed event(s)",
            :L1
          )
        end

        reorg_block = RollupReorgMonitorQueue.pop(__MODULE__)

        if !is_nil(reorg_block) && reorg_block > 0 do
          {deleted_count, _} = Repo.delete_all(from(r in OutputRoot, where: r.l1_block_number >= ^reorg_block))

          log_deleted_rows_count(reorg_block, deleted_count)

          Optimism.set_last_block_hash(@empty_hash, @counter_type)

          {:halt, if(reorg_block <= chunk_end, do: reorg_block - 1, else: chunk_end)}
        else
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          if chunk_end >= chunk_start do
            Optimism.set_last_block_hash_by_number(chunk_end, @counter_type, json_rpc_named_arguments)
          end

          {:cont, chunk_end}
        end
      end)

    if stop do
      Logger.warning("#{__MODULE__} is being stopped because dispute games exist.")
      Constants.set_constant_value(@stop_constant_key, "true")
      {:stop, :normal, state}
    else
      new_start_block = last_written_block + 1
      new_end_block = IndexerHelper.fetch_latest_l1_block_number(json_rpc_named_arguments)

      delay =
        if new_end_block == last_written_block do
          # there is no new block, so wait for some time to let the chain issue the new block
          max(block_check_interval - Timex.diff(Timex.now(), time_before, :milliseconds), 0)
        else
          0
        end

      Process.send_after(self(), :continue, delay)

      {:noreply, %{state | start_block: new_start_block, end_block: new_end_block, stop: dispute_games_exist?()}}
    end
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @doc """
    Stores the L1 `safe` and `finalized` block numbers as constants, so that the API can derive the L1
    finality of output roots without calling L1. A failed request keeps the previously stored value.

    ## Parameters
    - `json_rpc_named_arguments`: Configuration parameters for the L1 JSON RPC connection.
    - `retries`: Number of attempts per tag.

    ## Returns
    - `:ok`
  """
  @spec refresh_l1_heads(EthereumJSONRPC.json_rpc_named_arguments(), non_neg_integer()) :: :ok
  def refresh_l1_heads(json_rpc_named_arguments, retries \\ IndexerHelper.finite_retries_number()) do
    [
      {"safe", OutputRoot.l1_safe_block_number_constant()},
      {"finalized", OutputRoot.l1_finalized_block_number_constant()}
    ]
    |> Enum.each(fn {tag, constant_key} ->
      case IndexerHelper.get_block_number_by_tag(tag, json_rpc_named_arguments, retries) do
        {:ok, block_number} ->
          Constants.set_constant_value(constant_key, Integer.to_string(block_number))

        {:error, reason} ->
          Logger.warning(
            "Cannot refresh the L1 #{tag} block number, keeping the stored one. Reason: #{inspect(reason)}"
          )
      end
    end)
  end

  @doc """
    Reads the output oracle's `startingBlockNumber()` and stores it as a constant. The value never changes,
    so nothing is requested when the constant already exists.

    ## Parameters
    - `output_oracle`: L2OutputOracle contract address.
    - `json_rpc_named_arguments`: Configuration parameters for the L1 JSON RPC connection.
    - `retries`: Number of attempts.

    ## Returns
    - `:ok` when the constant is stored (now or before), `:error` when the call failed.
  """
  @spec store_starting_block_number(binary(), EthereumJSONRPC.json_rpc_named_arguments(), non_neg_integer()) ::
          :ok | :error
  def store_starting_block_number(
        output_oracle,
        json_rpc_named_arguments,
        retries \\ IndexerHelper.finite_retries_number()
      ) do
    if is_nil(Constants.get_constant_value(OutputRoot.starting_block_number_constant())) do
      case call_oracle_uint256(@starting_block_number_selector, output_oracle, json_rpc_named_arguments, retries) do
        {:ok, starting_block_number} ->
          Constants.set_constant_value(
            OutputRoot.starting_block_number_constant(),
            Integer.to_string(starting_block_number)
          )

          :ok

        :error ->
          :error
      end
    else
      :ok
    end
  end

  @doc """
    Stores the output oracle's `FINALIZATION_PERIOD_SECONDS()` as a constant, so that the API can derive the end
    of the challenge period without calling L1. The period can change on chain, so it is refreshed together with
    the L1 heads. A failed call keeps the previously stored value.

    ## Parameters
    - `output_oracle`: L2OutputOracle contract address.
    - `json_rpc_named_arguments`: Configuration parameters for the L1 JSON RPC connection.
    - `retries`: Number of attempts.

    ## Returns
    - `:ok`
  """
  @spec refresh_finalization_period(binary(), EthereumJSONRPC.json_rpc_named_arguments(), non_neg_integer()) :: :ok
  def refresh_finalization_period(
        output_oracle,
        json_rpc_named_arguments,
        retries \\ IndexerHelper.finite_retries_number()
      ) do
    case call_oracle_uint256(@finalization_period_selector, output_oracle, json_rpc_named_arguments, retries) do
      {:ok, period} ->
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), Integer.to_string(period))

      :error ->
        Logger.warning("Cannot refresh FINALIZATION_PERIOD_SECONDS() of the output oracle, keeping the stored one.")
    end

    :ok
  end

  # Calls a parameterless uint256 getter of the output oracle. An address without code answers with "0x",
  # so anything that is not a single 32-byte word is treated as an error rather than decoded.
  defp call_oracle_uint256(selector, output_oracle, json_rpc_named_arguments, retries) do
    request = Contract.eth_call_request(selector, output_oracle, 0, nil, nil)
    error_message = &"Cannot call #{selector} of the output oracle. Error: #{inspect(&1)}"

    with {:ok, "0x" <> word} when byte_size(word) == 64 <-
           IndexerHelper.repeated_call(&json_rpc/2, [request, json_rpc_named_arguments], error_message, retries),
         {value, ""} <- Integer.parse(word, 16) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp maybe_store_starting_block_number(%{starting_block_number_stored: true} = state), do: state

  defp maybe_store_starting_block_number(
         %{contract_address: output_oracle, json_rpc_named_arguments: json_rpc_named_arguments} = state
       ) do
    case store_starting_block_number(output_oracle, json_rpc_named_arguments) do
      :ok -> Map.put(state, :starting_block_number_stored, true)
      :error -> state
    end
  end

  # Refreshes the L1 heads at most once per `block_check_interval`; the loop runs back-to-back while catching up.
  defp maybe_refresh_l1_heads(
         %{json_rpc_named_arguments: json_rpc_named_arguments, block_check_interval: block_check_interval} = state
       ) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state, :l1_heads_refreshed_at) do
      refreshed_at when is_integer(refreshed_at) and now - refreshed_at < block_check_interval ->
        state

      _ ->
        refresh_l1_heads(json_rpc_named_arguments)
        refresh_finalization_period(state.contract_address, json_rpc_named_arguments)
        Map.put(state, :l1_heads_refreshed_at, now)
    end
  end

  defp dispute_games_exist? do
    DisputeGame.get_last_known_index() >= 0
  end

  defp events_to_output_roots(events) do
    Enum.map(events, fn event ->
      [l1_timestamp] = Helper.decode_data(event["data"], [{:uint, 256}])
      {:ok, l1_timestamp} = DateTime.from_unix(l1_timestamp)

      %{
        l2_output_index: quantity_to_integer(Enum.at(event["topics"], 2)),
        l2_block_number: quantity_to_integer(Enum.at(event["topics"], 3)),
        l1_transaction_hash: event["transactionHash"],
        l1_timestamp: l1_timestamp,
        l1_block_number: quantity_to_integer(event["blockNumber"]),
        output_root: Enum.at(event["topics"], 1)
      }
    end)
  end

  defp log_deleted_rows_count(reorg_block, count) do
    if count > 0 do
      Logger.warning(
        "As L1 reorg was detected, all rows with l1_block_number >= #{reorg_block} were removed from the op_output_roots table. Number of removed rows: #{count}."
      )
    end
  end

  @doc """
    Determines the last saved L1 block number, the last saved transaction hash, and the transaction info for Output Roots.

    Used by the `Indexer.Fetcher.Optimism` module to start fetching from a correct block number
    after reorg has occurred.

    ## Parameters
    - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
                                  Used to get transaction info by its hash from the RPC node.

    ## Returns
    - A tuple `{last_block_number, last_transaction_hash, last_transaction}` where
      `last_block_number` is the last block number found in the corresponding table (0 if not found),
      `last_transaction_hash` is the last transaction hash found in the corresponding table (nil if not found),
      `last_transaction` is the transaction info got from the RPC (nil if not found).
    - A tuple `{:error, message}` in case the `eth_getTransactionByHash` RPC request failed.
  """
  @spec get_last_l1_item(EthereumJSONRPC.json_rpc_named_arguments()) ::
          {non_neg_integer(), binary() | nil, map() | nil} | {:error, any()}
  def get_last_l1_item(json_rpc_named_arguments) do
    Optimism.get_last_item(
      :L1,
      &OutputRoot.last_root_l1_block_number_query/0,
      &OutputRoot.remove_roots_query/1,
      json_rpc_named_arguments,
      @counter_type
    )
  end

  @doc """
    Returns L1 RPC URL for this module.
  """
  @spec l1_rpc_url() :: binary() | nil
  def l1_rpc_url do
    Optimism.l1_rpc_url()
  end

  @doc """
    Determines if `Indexer.Fetcher.RollupL1ReorgMonitor` module must be up
    before this fetcher starts.

    ## Returns
    - `true` if the reorg monitor must be active, `false` otherwise.
  """
  @spec requires_l1_reorg_monitor?() :: boolean()
  def requires_l1_reorg_monitor? do
    Optimism.requires_l1_reorg_monitor?()
  end
end
