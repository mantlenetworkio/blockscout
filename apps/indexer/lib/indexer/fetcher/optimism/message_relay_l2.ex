defmodule Indexer.Fetcher.Optimism.MessageRelayL2 do
  @moduledoc """
    Fills the `op_message_relays` table with the relay results of deposits: the `RelayedMessage` and
    `FailedRelayedMessage` events of the L2CrossDomainMessenger.

    The L2 deposit transaction succeeds even when the messenger fails to deliver the message, so its receipt status
    cannot tell a delivered deposit from a failed one. The events are scanned from the block set by
    INDEXER_OPTIMISM_L2_MESSAGE_RELAYS_START_BLOCK (1 by default) to the chain head, and then in realtime. The
    messenger is the predeploy unless INDEXER_OPTIMISM_L2_CROSS_DOMAIN_MESSENGER_CONTRACT overrides it.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.Events.Subscriber
  alias Explorer.Chain.Optimism.MessageRelay
  alias Indexer.Fetcher.Optimism
  alias Indexer.Helper

  @fetcher_name :optimism_message_relays_l2

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
  def init(args) do
    {:ok, %{}, {:continue, args[:json_rpc_named_arguments]}}
  end

  # Checks the messenger address, subscribes to realtime blocks, finds the block to resume from, and starts the
  # catchup loop up to the current head. After the catchup the module handles the realtime block ranges.
  @impl GenServer
  def handle_continue(json_rpc_named_arguments, _state) do
    Logger.metadata(fetcher: @fetcher_name)

    # two seconds pause needed to avoid exceeding Supervisor restart intensity when DB issues
    :timer.sleep(2000)

    env = Application.get_all_env(:indexer)[__MODULE__]
    optimism_env = Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism]
    messenger = MessageRelay.l2_cross_domain_messenger()

    with {:messenger_valid, true} <- {:messenger_valid, Helper.address_correct?(messenger)},
         Subscriber.to(:blocks, :realtime),
         {:ok, latest_block_number} =
           Helper.get_block_number_by_tag("latest", json_rpc_named_arguments, Helper.infinite_retries_number()),
         {:ok, last_block_number} <- get_last_block_number(json_rpc_named_arguments) do
      Process.send(self(), :continue, [])

      {:noreply,
       %{
         start_block_number: max(env[:start_block], last_block_number),
         end_block_number: latest_block_number,
         chunk_size: optimism_env[:l2_eth_get_logs_range_size],
         mode: :catchup,
         realtime_range: nil,
         last_realtime_block_number: nil,
         messenger: messenger,
         json_rpc_named_arguments: json_rpc_named_arguments
       }}
    else
      {:messenger_valid, false} ->
        Logger.error(
          "L2CrossDomainMessenger address is invalid (INDEXER_OPTIMISM_L2_CROSS_DOMAIN_MESSENGER_CONTRACT). Deposit relay results are not indexed."
        )

        {:stop, :normal, %{}}

      {:error, error_data} ->
        Logger.error("Cannot get the last L2 relay transaction from RPC due to RPC error: #{inspect(error_data)}")
        {:stop, :normal, %{}}
    end
  end

  # Handles the current block range in chunks of INDEXER_OPTIMISM_L2_ETH_GET_LOGS_RANGE_SIZE blocks. A reorg reported
  # by the realtime block fetcher cuts the range at the reorg block. Without a reorg in the range, the module switches
  # to realtime mode, where `handle_info({:chain_event, :blocks, :realtime, blocks}, state)` forms the next range.
  @impl GenServer
  def handle_info(
        :continue,
        %{
          start_block_number: start_block_number,
          end_block_number: end_block_number,
          chunk_size: chunk_size,
          mode: mode,
          last_realtime_block_number: last_realtime_block_number,
          messenger: messenger,
          json_rpc_named_arguments: json_rpc_named_arguments
        } = state
      ) do
    {new_start_block_number, new_end_block_number, reorg_block_number} =
      start_block_number
      |> Range.new(end_block_number, 1)
      # lazily: the first catchup range spans tens of millions of blocks on mainnet
      |> Stream.chunk_every(chunk_size)
      |> Enum.reduce_while({nil, nil, nil}, fn block_numbers, _acc ->
        chunk_start = List.first(block_numbers)
        chunk_end = List.last(block_numbers)

        Helper.log_blocks_chunk_handling(chunk_start, chunk_end, start_block_number, end_block_number, nil, :L2)

        relays_count = handle_relays(chunk_start, chunk_end, messenger, json_rpc_named_arguments)

        Helper.log_blocks_chunk_handling(
          chunk_start,
          chunk_end,
          start_block_number,
          end_block_number,
          "#{relays_count} RelayedMessage/FailedRelayedMessage event(s).",
          :L2
        )

        reorg_block_number = Optimism.handle_reorgs_queue(__MODULE__, &handle_reorg/1)

        cond do
          is_nil(reorg_block_number) or reorg_block_number > end_block_number ->
            {:cont, {nil, nil, reorg_block_number}}

          reorg_block_number < start_block_number ->
            {:halt, {reorg_block_number, reorg_block_number, reorg_block_number}}

          true ->
            {:halt, {min(chunk_end + 1, reorg_block_number), reorg_block_number, reorg_block_number}}
        end
      end)

    new_last_realtime_block_number =
      if is_nil(reorg_block_number) do
        last_realtime_block_number
      else
        reorg_block_number
      end

    if is_nil(new_start_block_number) or is_nil(new_end_block_number) do
      if mode == :catchup do
        Optimism.log_catchup_loop_finished(start_block_number, end_block_number)
      end

      {:noreply, %{state | mode: :realtime, last_realtime_block_number: new_last_realtime_block_number}}
    else
      Process.send(self(), :continue, [])

      {:noreply,
       %{
         state
         | start_block_number: new_start_block_number,
           end_block_number: new_end_block_number,
           last_realtime_block_number: new_last_realtime_block_number
       }}
    end
  end

  @impl GenServer
  def handle_info({:chain_event, :blocks, :realtime, blocks}, state) do
    Optimism.handle_realtime_blocks(blocks, state)
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @doc """
    Removes the L2 relays from the reorg block on. Called by the main loop with the reorg block queued by the
    realtime block fetcher.

    ## Parameters
    - `reorg_block_number`: The reorg block number, or `nil` when there is no reorg.

    ## Returns
    - nothing.
  """
  @spec handle_reorg(non_neg_integer() | nil) :: any()
  def handle_reorg(reorg_block_number) when not is_nil(reorg_block_number) do
    {deleted_count, _} = Repo.delete_all(MessageRelay.remove_relays_from_block_query(:l2, reorg_block_number))

    if deleted_count > 0 do
      Logger.warning(
        "As L2 reorg was detected, all L2 rows with block_number >= #{reorg_block_number} were removed from the op_message_relays table. Number of removed rows: #{deleted_count}."
      )
    end
  end

  def handle_reorg(_reorg_block_number), do: :ok

  # Fetches the relay events of the block range from L2 and writes them to the database.
  @spec handle_relays(non_neg_integer(), non_neg_integer(), String.t(), EthereumJSONRPC.json_rpc_named_arguments()) ::
          non_neg_integer()
  defp handle_relays(start_block_number, end_block_number, messenger, json_rpc_named_arguments) do
    {:ok, events} =
      Helper.get_logs(
        start_block_number,
        end_block_number,
        messenger,
        [MessageRelay.relay_events()],
        json_rpc_named_arguments,
        0,
        Helper.infinite_retries_number()
      )

    relays = MessageRelay.events_to_relays(events, :l2)

    {:ok, _} =
      Chain.import(%{
        optimism_message_relays: %{params: relays},
        timeout: :infinity
      })

    Enum.count(relays)
  end

  @doc """
    Returns the block number of the last indexed L2 relay, after checking on RPC that its transaction still
    exists. When it does not (a reorg), the relays of that block are removed and the previous relay is checked.

    ## Parameters
    - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.

    ## Returns
    - `{:ok, number}` with the block number, `0` when there are no L2 relays.
    - `{:error, message}` in case of RPC error.
  """
  @spec get_last_block_number(EthereumJSONRPC.json_rpc_named_arguments()) ::
          {:ok, non_neg_integer()} | {:error, any()}
  def get_last_block_number(json_rpc_named_arguments) do
    {last_block_number, last_transaction_hash} = Repo.one(MessageRelay.last_relay_query(:l2)) || {0, nil}

    with {:empty_hash, false} <- {:empty_hash, is_nil(last_transaction_hash)},
         {:ok, last_transaction} <- Helper.get_transaction_by_hash(last_transaction_hash, json_rpc_named_arguments),
         {:empty_transaction, false} <- {:empty_transaction, is_nil(last_transaction)} do
      {:ok, last_block_number}
    else
      {:empty_hash, true} ->
        {:ok, 0}

      {:error, _} = error ->
        error

      {:empty_transaction, true} ->
        Logger.error(
          "Cannot find the last L2 relay transaction #{last_transaction_hash} on RPC. Probably, there was a reorg. Removing its block from op_message_relays and checking the previous relay..."
        )

        Repo.delete_all(MessageRelay.remove_block_relays_query(:l2, last_block_number))

        get_last_block_number(json_rpc_named_arguments)
    end
  end

  def fetcher_name, do: @fetcher_name
end
