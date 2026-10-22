defmodule Indexer.Fetcher.Optimism.Deposit do
  @moduledoc """
  Fills op_deposits DB table.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  import EthereumJSONRPC, only: [quantity_to_integer: 1]
  import Explorer.Helper, only: [decode_data: 2]

  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.Cache.Counters.LastFetchedCounter
  alias Explorer.Chain.Events.Publisher
  alias Explorer.Chain.Optimism.{BridgeMessage, Deposit}
  alias Indexer.Fetcher.Optimism
  alias Indexer.Helper
  alias Indexer.RollupReorgMonitorQueue

  # 32-byte signature of the event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData)
  @transaction_deposited_event "0xb3813568d9991fc951961fcb4c784893574240a28925604d09fc577c55bb7c32"

  @fetcher_name :optimism_deposits
  @address_prefix "0x000000000000000000000000"
  # The fetcher's checkpoint: the hash of the last L1 block it handled. Deposits indexed before creation deposits and
  # Mantle v0 events were derived the way op-node derives them are checkpointed under the previous name,
  # `optimism_deposits_fetcher_last_l1_block_hash`, so the fetcher derives them again (see `get_last_l1_item/1`).
  @counter_type "optimism_deposits_fetcher_last_l1_block_hash_v2"
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

    Optimism.init_continue(nil, __MODULE__)
  end

  @impl GenServer
  def handle_info(
        :continue,
        %{
          contract_address: optimism_portal,
          block_check_interval: block_check_interval,
          start_block: start_block,
          end_block: end_block,
          json_rpc_named_arguments: json_rpc_named_arguments,
          eth_get_logs_range_size: eth_get_logs_range_size
        } = state
      ) do
    # credo:disable-for-next-line
    time_before = Timex.now()

    transaction_type = Application.get_all_env(:indexer)[__MODULE__][:transaction_type]

    chunks_number = ceil((end_block - start_block + 1) / eth_get_logs_range_size)
    chunk_range = Range.new(0, max(chunks_number - 1, 0), 1)

    last_written_block =
      chunk_range
      |> Enum.reduce_while(start_block - 1, fn current_chunk, _ ->
        chunk_start = start_block + eth_get_logs_range_size * current_chunk
        chunk_end = min(chunk_start + eth_get_logs_range_size - 1, end_block)

        if chunk_end >= chunk_start do
          Helper.log_blocks_chunk_handling(chunk_start, chunk_end, start_block, end_block, nil, :L1)

          {:ok, result} =
            Helper.get_logs(
              chunk_start,
              chunk_end,
              optimism_portal,
              [@transaction_deposited_event],
              json_rpc_named_arguments,
              0,
              Helper.infinite_retries_number()
            )

          deposit_events = prepare_events(result, transaction_type, json_rpc_named_arguments)

          {:ok, _} =
            Chain.import(%{
              optimism_deposits: %{params: deposit_events},
              timeout: :infinity
            })

          remove_stale_deposits(chunk_start, chunk_end, deposit_events)

          Publisher.broadcast(%{new_optimism_deposits: deposit_events}, :realtime)

          Helper.log_blocks_chunk_handling(
            chunk_start,
            chunk_end,
            start_block,
            end_block,
            "#{Enum.count(deposit_events)} TransactionDeposited event(s)",
            :L1
          )
        end

        reorg_block = RollupReorgMonitorQueue.pop(__MODULE__)

        if !is_nil(reorg_block) && reorg_block > 0 do
          {deleted_count, _} = Repo.delete_all(from(d in Deposit, where: d.l1_block_number >= ^reorg_block))

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

  defp log_deleted_rows_count(reorg_block, count) do
    if count > 0 do
      Logger.warning(
        "As L1 reorg was detected, all rows with l1_block_number >= #{reorg_block} were removed from the op_deposits table. Number of removed rows: #{count}."
      )
    end
  end

  # Removes the rows of the L1 blocks just handled that their deposits do not include. While a deployment rolls over,
  # a fetcher of an earlier version can import rows after this one removed the rows it derived (`get_last_l1_item/1`).
  defp remove_stale_deposits(chunk_start, chunk_end, deposit_events) do
    l2_transaction_hashes = Enum.map(deposit_events, & &1.l2_transaction_hash)

    {count, _} =
      Repo.delete_all(
        from(d in Deposit,
          where:
            d.l1_block_number >= ^chunk_start and d.l1_block_number <= ^chunk_end and
              d.l2_transaction_hash not in ^l2_transaction_hashes
        ),
        timeout: :infinity
      )

    if count > 0 do
      Logger.warning(
        "Removed #{count} row(s) of the op_deposits table in L1 blocks #{chunk_start}..#{chunk_end} that the deposits of these blocks do not include."
      )
    end
  end

  # Prepares `TransactionDeposited` events to be imported to database.
  #
  # ## Parameters
  # - `events`: The list of `TransactionDeposited` events got from `eth_getLogs` response.
  # - `transaction_type`: L1 transaction type to correctly calculate the corresponding L2 transaction hash.
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  #                               Used to get blocks info by their numbers from the RPC node.
  #
  # ## Returns
  # - A list of prepared events. Each list item is a map outlining a deposit event. The events that cannot be parsed
  #   are left out (see `event_to_deposit/5`).
  @spec prepare_events(list(), non_neg_integer(), EthereumJSONRPC.json_rpc_named_arguments()) :: [map()]
  defp prepare_events(events, transaction_type, json_rpc_named_arguments) do
    {timestamps, origins} =
      events
      |> Helper.get_blocks_by_events(json_rpc_named_arguments, Helper.infinite_retries_number(), true)
      |> Enum.reduce({%{}, %{}}, fn block, {timestamps_acc, origins_acc} ->
        block_number = quantity_to_integer(Map.get(block, "number"))
        {:ok, timestamp} = DateTime.from_unix(quantity_to_integer(Map.get(block, "timestamp")))

        new_timestamps_acc = Map.put(timestamps_acc, block_number, timestamp)

        new_origins_acc =
          block
          |> Map.get("transactions", [])
          |> Enum.reduce(origins_acc, fn transaction, acc ->
            Map.put(acc, String.downcase(transaction["hash"]), transaction["from"])
          end)

        {new_timestamps_acc, new_origins_acc}
      end)

    bridges = BridgeMessage.bridges()

    events
    |> Enum.map(&event_to_deposit(&1, timestamps, origins, transaction_type, bridges))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
    Prepares a `TransactionDeposited` event to be imported to database, with the bridge transfer its message carries.

    The L2 transaction is derived the way op-node derives it: the event's version (`topics[3]`) selects the opaqueData
    layout, and a contract creation has no `to`. An event op-node would refuse as well (an unknown version, or
    opaqueData too short for its version) is logged and skipped.

    ## Parameters
    - An event map outlining a `TransactionDeposited` event got from `eth_getLogs` response.
    - `timestamps`: A `block_number -> timestamp` map to get the timestamp of the event from its block info.
    - `origins`: A `transaction_hash -> origin` map to get the origin address of the event transaction.
    - `transaction_type`: L1 transaction type to correctly calculate the corresponding L2 transaction hash.
    - `bridges`: The addresses returned by `Explorer.Chain.Optimism.BridgeMessage.bridges/0`. With `nil` the transfer
      is not decoded.

    ## Returns
    - A map with the event info ready to be imported to database, or `nil` when the event cannot be parsed.
  """
  @spec event_to_deposit(map(), map(), map(), non_neg_integer(), BridgeMessage.bridges() | nil) :: map() | nil
  def event_to_deposit(
        %{
          "transactionHash" => transaction_hash,
          "logIndex" => log_index,
          "topics" => [_, _, _, version_topic],
          "data" => opaque_data
        } = event,
        timestamps,
        origins,
        transaction_type,
        bridges
      ) do
    [raw_opaque_data] = decode_data(opaque_data, [:bytes])
    version = quantity_to_integer(version_topic)

    case parse_opaque_data(raw_opaque_data, version, mantle_mode?()) do
      {:ok, opaque} ->
        derive_deposit(event, opaque, timestamps, origins, transaction_type, bridges)

      :error ->
        Logger.error(
          "Skipped the TransactionDeposited event #{quantity_to_integer(log_index)} of the L1 transaction #{transaction_hash}: its opaqueData does not parse as version #{version}."
        )

        nil
    end
  end

  defp derive_deposit(
         %{
           "blockHash" => "0x" <> stripped_block_hash,
           "blockNumber" => block_number_quantity,
           "transactionHash" => transaction_hash,
           "logIndex" => "0x" <> stripped_log_index,
           "topics" => [_, @address_prefix <> from_stripped, @address_prefix <> to_stripped, _]
         },
         opaque,
         timestamps,
         origins,
         transaction_type,
         bridges
       ) do
    {_, prefixed_block_hash} = (String.pad_leading("", 64, "0") <> stripped_block_hash) |> String.split_at(-64)
    {_, prefixed_log_index} = (String.pad_leading("", 64, "0") <> stripped_log_index) |> String.split_at(-64)

    deposit_id_hash =
      "#{prefixed_block_hash}#{prefixed_log_index}"
      |> Base.decode16!(case: :mixed)
      |> ExKeccak.hash_256()
      |> Base.encode16(case: :lower)

    source_hash =
      "#{String.pad_leading("", 64, "0")}#{deposit_id_hash}"
      |> Base.decode16!(case: :mixed)
      |> ExKeccak.hash_256()

    is_system = <<0>>

    # op-node leaves `To` nil for a contract creation, and a nil `To` (`rlp:"nil"`) is an empty string in the RLP
    to = if opaque.creation?, do: <<>>, else: Base.decode16!(to_stripped, case: :mixed)

    # `message` holds what the L2 transaction delivers to `to`: its calldata and the values it transfers (`Mint` and
    # `EthValue` are minted to `from` first)
    {rlp_encoded, message} =
      case opaque do
        %{mnt_mint: mnt_mint, mnt_value: mnt_value, eth_mint: eth_mint, eth_tx_value: eth_tx_value} ->
          # Mantle DepositTx RLP (from op-geth deposit_tx.go):
          #   [SourceHash, From, To, Mint, Value, Gas, IsSystemTx, EthValue, Data, EthTxValue?]
          #
          # Go RLP encoding rules:
          #   IsSystemTx false → <<>> (empty bytes, RLP 0x80)
          #   EthValue *big.Int rlp:"nil": non-nil 0 → <<>> (RLP 0x80)
          #   EthTxValue *big.Int rlp:"optional": nil/zero → field OMITTED entirely
          base_fields = [
            source_hash,
            from_stripped |> Base.decode16!(case: :mixed),
            to,
            mnt_mint |> String.replace_leading(<<0>>, <<>>),
            mnt_value |> String.replace_leading(<<0>>, <<>>),
            opaque.gas_limit |> String.replace_leading(<<0>>, <<>>),
            is_system |> String.replace_leading(<<0>>, <<>>),
            eth_mint |> String.replace_leading(<<0>>, <<>>),
            opaque.data
          ]

          # EthTxValue: only include if non-zero (Go rlp:"optional" omits zero/nil)
          eth_tx_value_stripped = eth_tx_value |> String.replace_leading(<<0>>, <<>>)

          fields =
            if eth_tx_value_stripped != <<>> do
              base_fields ++ [eth_tx_value_stripped]
            else
              base_fields
            end

          {ExRLP.encode(fields, encoding: :hex),
           %{
             data: opaque.data,
             mnt_value: :binary.decode_unsigned(mnt_value),
             eth_value: :binary.decode_unsigned(eth_tx_value)
           }}

        %{msg_value: msg_value, value: value} ->
          # Standard OP DepositTx RLP (8 fields):
          #   [SourceHash, From, To, Mint, Value, Gas, IsSystemTx, Data]
          {ExRLP.encode(
             [
               source_hash,
               from_stripped |> Base.decode16!(case: :mixed),
               to,
               msg_value |> String.replace_leading(<<0>>, <<>>),
               value |> String.replace_leading(<<0>>, <<>>),
               opaque.gas_limit |> String.replace_leading(<<0>>, <<>>),
               is_system |> String.replace_leading(<<0>>, <<>>),
               opaque.data
             ],
             encoding: :hex
           ), %{data: opaque.data, mnt_value: nil, eth_value: :binary.decode_unsigned(value)}}
      end

    transaction_type =
      transaction_type
      |> Integer.to_string(16)
      |> String.downcase()

    l2_transaction_hash =
      "0x" <>
        ((transaction_type <> "#{rlp_encoded}")
         |> Base.decode16!(case: :mixed)
         |> ExKeccak.hash_256()
         |> Base.encode16(case: :lower))

    block_number = quantity_to_integer(block_number_quantity)

    transfer =
      message
      |> Map.merge(%{
        from: "0x" <> String.downcase(from_stripped),
        to: if(opaque.creation?, do: nil, else: "0x" <> String.downcase(to_stripped))
      })
      |> BridgeMessage.decode_deposit(bridges)

    Map.merge(
      %{
        l1_block_number: block_number,
        l1_block_timestamp: Map.get(timestamps, block_number),
        l1_transaction_hash: transaction_hash,
        l1_transaction_origin: Map.get(origins, String.downcase(transaction_hash)),
        l2_transaction_hash: l2_transaction_hash
      },
      transfer
    )
  end

  # Parses opaqueData by the event's version, as op-node does (`unmarshalDepositVersion0/1` in
  # op-node/rollup/derive/deposit_log.go), and returns `:error` for a version or a length op-node refuses.
  #
  # Mantle opaqueData (version 0 has no `eth_tx_value`: the Mantle Sepolia portal emitted it until July 2024):
  #   v0: [mnt_mint(32), mnt_value(32), eth_mint(32), gas_limit(8), is_creation(1), data]
  #   v1: [mnt_mint(32), mnt_value(32), eth_mint(32), eth_tx_value(32), gas_limit(8), is_creation(1), data]
  #
  # Mantle DepositTx RLP field mapping (from op-geth deposit_tx.go):
  #   Mint       = mnt_mint     — MNT to mint on L2
  #   Value      = mnt_value    — MNT to transfer
  #   EthValue   = eth_mint     — ETH/BVM_ETH to mint
  #   EthTxValue = eth_tx_value — ETH to transfer
  #
  # Standard OP opaqueData, version 0 only:
  #   v0: [msg_value(32), value(32), gas_limit(8), is_creation(1), data]
  #
  # A non-zero is_creation byte makes the deposit a contract creation.
  @spec parse_opaque_data(binary() | nil, non_neg_integer(), boolean()) :: {:ok, map()} | :error
  defp parse_opaque_data(
         <<mnt_mint::binary-size(32), mnt_value::binary-size(32), eth_mint::binary-size(32),
           eth_tx_value::binary-size(32), gas_limit::binary-size(8), is_creation::binary-size(1), data::binary>>,
         1,
         true
       ) do
    {:ok,
     %{
       mnt_mint: mnt_mint,
       mnt_value: mnt_value,
       eth_mint: eth_mint,
       eth_tx_value: eth_tx_value,
       gas_limit: gas_limit,
       creation?: is_creation != <<0>>,
       data: data
     }}
  end

  defp parse_opaque_data(
         <<mnt_mint::binary-size(32), mnt_value::binary-size(32), eth_mint::binary-size(32), gas_limit::binary-size(8),
           is_creation::binary-size(1), data::binary>>,
         0,
         true
       ) do
    {:ok,
     %{
       mnt_mint: mnt_mint,
       mnt_value: mnt_value,
       eth_mint: eth_mint,
       eth_tx_value: <<>>,
       gas_limit: gas_limit,
       creation?: is_creation != <<0>>,
       data: data
     }}
  end

  defp parse_opaque_data(
         <<msg_value::binary-size(32), value::binary-size(32), gas_limit::binary-size(8), is_creation::binary-size(1),
           data::binary>>,
         0,
         false
       ) do
    {:ok,
     %{
       msg_value: msg_value,
       value: value,
       gas_limit: gas_limit,
       creation?: is_creation != <<0>>,
       data: data
     }}
  end

  defp parse_opaque_data(_raw_opaque_data, _version, _mantle_mode?), do: :error

  defp mantle_mode? do
    Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism][:mantle_mode] == true
  end

  @doc """
    Determines the last saved L1 block number, the last saved transaction hash, and the transaction info for L1 Deposit events.

    Used by the `Indexer.Fetcher.Optimism` module to start fetching from a correct block number
    after reorg has occurred.

    Without a checkpoint of its own, the fetcher removes every deposit and starts over from the start block: the
    deposits were derived the way earlier versions of this fetcher derived them, or there are none yet.

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
    if is_nil(LastFetchedCounter.get(@counter_type, nullable: true)) do
      # the same check again in the statement, so that it never removes the rows of a fetcher that checkpointed since
      {deleted_count, _} =
        Repo.delete_all(
          from(d in Deposit,
            where: not exists(from(c in LastFetchedCounter, where: c.counter_type == ^@counter_type, select: 1))
          ),
          timeout: :infinity
        )

      if deleted_count > 0 do
        Logger.warning(
          "Removed all #{deleted_count} rows of the op_deposits table, indexed without a checkpoint of this fetcher, to derive them again from the start block."
        )
      end

      {0, nil, nil}
    else
      Optimism.get_last_item(
        :L1,
        &Deposit.last_deposit_l1_block_number_query/0,
        &Deposit.remove_deposits_query/1,
        json_rpc_named_arguments,
        @counter_type
      )
    end
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
