defmodule Indexer.Fetcher.Optimism.MessageRelayL1 do
  @moduledoc """
    Fills the `op_message_relays` table with the relay results of withdrawals: the `RelayedMessage` and
    `FailedRelayedMessage` events of the L1CrossDomainMessenger.

    The portal's `WithdrawalFinalized` event cannot tell whether a withdrawal was delivered. It is emitted with
    `success = true` when the messenger fails to deliver the message, and a later replay calls the messenger
    directly. The messenger address comes from INDEXER_OPTIMISM_L1_CROSS_DOMAIN_MESSENGER_CONTRACT; without it the
    module does not start. Scanning starts at the OptimismPortal start block, like the other Optimism L1 fetchers.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.Optimism.MessageRelay
  alias Indexer.Fetcher.Optimism
  alias Indexer.Helper
  alias Indexer.RollupReorgMonitorQueue

  @fetcher_name :optimism_message_relays_l1
  @counter_type "optimism_message_relays_l1_fetcher_last_l1_block_hash"
  @empty_hash "0x0000000000000000000000000000000000000000000000000000000000000000"

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

    messenger = Application.get_all_env(:indexer)[__MODULE__][:l1_cross_domain_messenger]

    if Helper.address_correct?(messenger) do
      Optimism.init_continue(messenger, __MODULE__)
    else
      Logger.error(
        "L1CrossDomainMessenger address is invalid or not defined (INDEXER_OPTIMISM_L1_CROSS_DOMAIN_MESSENGER_CONTRACT). Withdrawal relay results are not indexed."
      )

      {:stop, :normal, %{}}
    end
  end

  @impl GenServer
  def handle_info(
        :continue,
        %{
          contract_address: messenger,
          block_check_interval: block_check_interval,
          start_block: start_block,
          end_block: end_block,
          json_rpc_named_arguments: json_rpc_named_arguments,
          eth_get_logs_range_size: eth_get_logs_range_size
        } = state
      ) do
    # credo:disable-for-next-line
    time_before = Timex.now()

    chunks_number = ceil((end_block - start_block + 1) / eth_get_logs_range_size)
    chunk_range = Range.new(0, max(chunks_number - 1, 0), 1)

    last_written_block =
      chunk_range
      |> Enum.reduce_while(start_block - 1, fn current_chunk, _ ->
        chunk_start = start_block + eth_get_logs_range_size * current_chunk
        chunk_end = min(chunk_start + eth_get_logs_range_size - 1, end_block)

        if chunk_end >= chunk_start do
          handle_chunk(chunk_start, chunk_end, start_block, end_block, messenger, json_rpc_named_arguments)
        end

        reorg_block = RollupReorgMonitorQueue.pop(__MODULE__)

        if !is_nil(reorg_block) && reorg_block > 0 do
          {deleted_count, _} = Repo.delete_all(MessageRelay.remove_relays_from_block_query(:l1, reorg_block))

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

    new_start_block = last_written_block + 1
    new_end_block = Helper.fetch_latest_l1_block_number(json_rpc_named_arguments)

    delay =
      if new_end_block == last_written_block do
        # there is no new block, so wait for some time to let the chain issue the new block
        max(block_check_interval - Timex.diff(Timex.now(), time_before, :milliseconds), 0)
      else
        0
      end

    Process.send_after(self(), :continue, delay)

    {:noreply, %{state | start_block: new_start_block, end_block: new_end_block}}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Fetches the relay events of the block range from L1 and writes them to the database.
  defp handle_chunk(chunk_start, chunk_end, start_block, end_block, messenger, json_rpc_named_arguments) do
    Helper.log_blocks_chunk_handling(chunk_start, chunk_end, start_block, end_block, nil, :L1)

    {:ok, events} =
      Helper.get_logs(
        chunk_start,
        chunk_end,
        messenger,
        [MessageRelay.relay_events()],
        json_rpc_named_arguments,
        0,
        Helper.infinite_retries_number()
      )

    relays = MessageRelay.events_to_relays(events, :l1)

    {:ok, _} =
      Chain.import(%{
        optimism_message_relays: %{params: relays},
        timeout: :infinity
      })

    Helper.log_blocks_chunk_handling(
      chunk_start,
      chunk_end,
      start_block,
      end_block,
      "#{Enum.count(relays)} RelayedMessage/FailedRelayedMessage event(s)",
      :L1
    )
  end

  defp log_deleted_rows_count(reorg_block, count) do
    if count > 0 do
      Logger.warning(
        "As L1 reorg was detected, all L1 rows with block_number >= #{reorg_block} were removed from the op_message_relays table. Number of removed rows: #{count}."
      )
    end
  end

  @doc """
    Determines the last saved L1 block number, the last saved transaction hash, and the transaction info for
    L1 message relays. Used by `Indexer.Fetcher.Optimism.init_continue/2` to resume after a restart or a reorg.

    ## Parameters
    - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.

    ## Returns
    - A tuple `{last_block_number, last_transaction_hash, last_transaction}`, or `{:error, message}` when the
      `eth_getTransactionByHash` request failed.
  """
  @spec get_last_l1_item(EthereumJSONRPC.json_rpc_named_arguments()) ::
          {non_neg_integer(), binary() | nil, map() | nil} | {:error, any()}
  def get_last_l1_item(json_rpc_named_arguments) do
    Optimism.get_last_item(
      :L1,
      fn -> MessageRelay.last_relay_query(:l1) end,
      &MessageRelay.remove_block_relays_query(:l1, &1),
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
    Determines if `Indexer.Fetcher.RollupL1ReorgMonitor` module must be up before this fetcher starts.
  """
  @spec requires_l1_reorg_monitor?() :: boolean()
  def requires_l1_reorg_monitor? do
    Optimism.requires_l1_reorg_monitor?()
  end
end
