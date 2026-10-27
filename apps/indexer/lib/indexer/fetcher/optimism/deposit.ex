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
  # The fetcher's checkpoint: the number and the hash of the last L1 block it handled, as one value (a counter holds a
  # number: block number × 2^256 + hash), and the hash alone under the name the previous version reads and writes (see
  # `check_checkpoint/1`). Deposits indexed before creation deposits and Mantle v0 events were derived the way op-node
  # derives them are checkpointed under the previous name of the hash, `optimism_deposits_fetcher_last_l1_block_hash`,
  # so the fetcher derives them again (see `get_last_l1_item/1`).
  @counter_type "optimism_deposits_fetcher_last_l1_block_hash_v2"
  @counter_type_block "optimism_deposits_fetcher_last_l1_block_v2"
  @hash_values Integer.pow(2, 256)
  @empty_hash "0x0000000000000000000000000000000000000000000000000000000000000000"
  # How many L1 blocks before a reported reorg the deposits are derived again: three epochs, which no reorg of
  # unfinalized blocks goes deeper than while the chain finalizes
  @reorg_depth 96
  # The default pause before the fetcher handles again a chunk with an event it cannot parse
  @stall_retry_interval :timer.minutes(1)

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

    case Optimism.init_continue(nil, __MODULE__) do
      {:noreply, state} -> {:noreply, check_checkpoint(state)}
      stop -> stop
    end
  end

  @impl GenServer
  def handle_info(
        :continue,
        %{
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

    {last_written_block, stalled?} =
      chunk_range
      |> Enum.reduce_while({start_block - 1, false}, fn current_chunk, _ ->
        chunk_start = start_block + eth_get_logs_range_size * current_chunk
        chunk_end = min(chunk_start + eth_get_logs_range_size - 1, end_block)

        if chunk_end < chunk_start or import_chunk(chunk_start, chunk_end, state, transaction_type) == :ok do
          {action, last_block} = handle_reorg_or_checkpoint(chunk_start, chunk_end, state)
          {action, {last_block, false}}
        else
          {:halt, {chunk_start - 1, true}}
        end
      end)

    new_start_block = last_written_block + 1
    new_end_block = Helper.fetch_latest_l1_block_number(json_rpc_named_arguments)

    delay =
      cond do
        stalled? ->
          stall_retry_interval()

        new_end_block == last_written_block ->
          # there is no new block, so wait for some time to let the chain issue the new block
          max(block_check_interval - Timex.diff(Timex.now(), time_before, :milliseconds), 0)

        true ->
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

  # Imports the deposits of L1 blocks chunk_start..chunk_end and removes the rows of these blocks that they do not
  # include. Returns `:error`, importing nothing, when an event of the chunk does not parse (see `prepare_events/3`).
  @spec import_chunk(non_neg_integer(), non_neg_integer(), map(), non_neg_integer()) :: :ok | :error
  defp import_chunk(
         chunk_start,
         chunk_end,
         %{
           contract_address: optimism_portal,
           start_block: start_block,
           end_block: end_block,
           json_rpc_named_arguments: json_rpc_named_arguments
         },
         transaction_type
       ) do
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

    case prepare_events(result, transaction_type, json_rpc_named_arguments) do
      {:ok, deposit_events} ->
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

        :ok

      :error ->
        Logger.error(
          "The deposits of L1 blocks #{chunk_start}..#{chunk_end} are not imported, as an event of these blocks does not parse. Retrying in #{div(stall_retry_interval(), 1000)} seconds..."
        )

        :error
    end
  end

  # The block after the finalized one, or `fallback` when the L1 node cannot tell
  defp first_unfinalized_block(fallback, json_rpc_named_arguments) do
    case Helper.get_block_number_by_tag("finalized", json_rpc_named_arguments) do
      {:ok, finalized_block} -> finalized_block + 1
      {:error, _} -> fallback
    end
  end

  defp stall_retry_interval do
    Application.get_all_env(:indexer)[__MODULE__][:stall_retry_interval] || @stall_retry_interval
  end

  # Handles the L1 reorg found meanwhile, if any (see `rewind/3`), or else checkpoints the chunk. Returns the reduce
  # action and the last block handled.
  defp handle_reorg_or_checkpoint(
         chunk_start,
         chunk_end,
         %{json_rpc_named_arguments: json_rpc_named_arguments} = state
       ) do
    reorg_block = RollupReorgMonitorQueue.pop(__MODULE__)

    if !is_nil(reorg_block) && reorg_block > 0 do
      {:halt, rewind(reorg_block, chunk_end, state)}
    else
      with true <- chunk_end >= chunk_start,
           [%{"hash" => hash}] <-
             Optimism.get_blocks_by_numbers([chunk_end], json_rpc_named_arguments, Helper.infinite_retries_number()) do
        set_checkpoint(chunk_end, hash)
      end

      {:cont, chunk_end}
    end
  end

  # Derives the deposits again after an L1 reorg at `reorg_block`: removes the rows from the first block to derive
  # again and checkpoints the block before it, not after `last_handled_block`, together. Returns the checkpoint block.
  #
  # The reorg monitor reports the block whose hash changed, which can be above the first block the reorg replaced, and
  # its report can be handled after the replacing blocks are finalized. So the deposits are derived again from
  # `@reorg_depth` blocks before the reported block, or from the first block that is not finalized if that is earlier
  # (not before the start block). The checkpoint names the block before it, as the fetcher does not take up from its
  # last row on a restart (see `get_last_l1_item/1`).
  defp rewind(
         reorg_block,
         last_handled_block,
         %{start_block_l1: start_block_l1, json_rpc_named_arguments: json_rpc_named_arguments}
       ) do
    earliest_reorg_block = reorg_block - @reorg_depth

    from_block =
      earliest_reorg_block
      |> min(first_unfinalized_block(earliest_reorg_block, json_rpc_named_arguments))
      |> max(start_block_l1)

    last_block = min(from_block - 1, last_handled_block)
    {checkpoint_block, checkpoint_hash} = reorg_checkpoint(last_block, start_block_l1, json_rpc_named_arguments)

    # together, so that no checkpoint stays after the rows it covers are removed
    {:ok, deleted_count} =
      Repo.transaction(fn ->
        {deleted_count, _} = Repo.delete_all(from(d in Deposit, where: d.l1_block_number >= ^from_block))
        set_checkpoint(checkpoint_block, checkpoint_hash)
        deleted_count
      end)

    log_deleted_rows_count(from_block, deleted_count)

    last_block
  end

  # The checkpoint of the last block kept by a reorg: none before the start block, which `Optimism.init_continue/2`
  # would refuse on a restart (without a checkpoint the fetcher takes up from the start block)
  defp reorg_checkpoint(last_block, start_block_l1, _json_rpc_named_arguments) when last_block < start_block_l1,
    do: {0, @empty_hash}

  defp reorg_checkpoint(last_block, _start_block_l1, json_rpc_named_arguments),
    do: {last_block, block_hash_by_number(last_block, json_rpc_named_arguments)}

  # The hash of the L1 block `block_number`, waiting for an L1 node that does not return the block (it lags behind): a
  # checkpoint with no hash, or a stale one, could not be told from one a fetcher of the previous version writes (see
  # `check_checkpoint/1`)
  defp block_hash_by_number(block_number, json_rpc_named_arguments) do
    case Optimism.get_block_by_number(block_number, json_rpc_named_arguments) do
      {:ok, %{"hash" => hash}} ->
        hash

      {:ok, nil} ->
        Optimism.log_error_message_with_retry_sleep("The L1 node does not return the block #{block_number}.")
        block_hash_by_number(block_number, json_rpc_named_arguments)
    end
  end

  # Writes the checkpoint of `block_number`: the number and the hash of the block, and the hash alone under the
  # previous name, together. The block number 0 stands for no checkpoint.
  defp set_checkpoint(block_number, block_hash) do
    {hash, ""} = block_hash |> String.trim_leading("0x") |> Integer.parse(16)

    {:ok, _} =
      Repo.transaction(fn ->
        Optimism.set_last_block_hash(block_hash, @counter_type)

        {:ok, _} =
          LastFetchedCounter.upsert(%{counter_type: @counter_type_block, value: block_number * @hash_values + hash})
      end)
  end

  defp log_deleted_rows_count(reorg_block, count) do
    if count > 0 do
      Logger.warning(
        "As L1 reorg was detected, all rows with l1_block_number >= #{reorg_block} were removed from the op_deposits table. Number of removed rows: #{count}."
      )
    end
  end

  # Removes the rows of the L1 blocks just handled that their deposits do not include: rows derived the way earlier
  # versions of this fetcher derived them (see `get_last_l1_item/1`), including those a fetcher of an earlier version
  # keeps importing while a deployment rolls over.
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
  # - `{:ok, deposits}` with a map outlining each deposit event.
  # - `:error` when an event does not parse (see `event_to_deposit/5`). op-node halts on such an event, so the chain
  #   has none: the derivation is wrong or misconfigured, and the deposit's L2 transaction exists, so the caller must
  #   not leave the deposit out.
  @spec prepare_events(list(), non_neg_integer(), EthereumJSONRPC.json_rpc_named_arguments()) :: {:ok, [map()]} | :error
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

    deposits = Enum.map(events, &event_to_deposit(&1, timestamps, origins, transaction_type, bridges))

    if Enum.any?(deposits, &is_nil/1), do: :error, else: {:ok, deposits}
  end

  @doc """
    Prepares a `TransactionDeposited` event to be imported to database, with the bridge transfer its message carries.

    The L2 transaction is derived the way op-node derives it: the event's version (`topics[3]`) selects the opaqueData
    layout, and a contract creation has no `to`. An event op-node cannot derive either (an unknown version, or
    opaqueData too short for its version) is logged and gives `nil`; op-node halts on such an event.

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
          "Cannot derive the L2 transaction of the TransactionDeposited event #{quantity_to_integer(log_index)} of the L1 transaction #{transaction_hash}: its opaqueData does not parse as version #{version}."
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
    Determines the last L1 block the fetcher handled, for the `Indexer.Fetcher.Optimism` module to start fetching from
    the block after it.

    The fetcher takes up after the block its checkpoint names, once `check_checkpoint/1` finds it on the chain of the
    L1 node. Without a checkpoint of its own (the deposits were derived the way earlier versions of this fetcher
    derived them, or there are none yet), the fetcher derives every deposit again from the start block, as it does with
    a checkpoint of an earlier version that has no block number and whose hash the L1 node does not find. It does not
    take up from its last row: while a deployment rolls over, a fetcher of the previous version can import rows ahead
    of this one. The rows stay until the chunk of their L1 block replaces them (see `remove_stale_deposits/3`), so the
    deposits stay visible meanwhile and a rollback to an earlier version finds them all.

    ## Parameters
    - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
                                  Used to get the block of a checkpoint without a number by its hash from the RPC node.

    ## Returns
    - A tuple `{last_block_number, nil, nil}`, where `last_block_number` is the block the checkpoint names, or 0 to start
      from the start block.
  """
  @spec get_last_l1_item(EthereumJSONRPC.json_rpc_named_arguments()) :: {non_neg_integer(), nil, nil}
  def get_last_l1_item(json_rpc_named_arguments) do
    case read_checkpoint() do
      {block_number, block_hash, block_hash} when block_number > 0 and block_hash != @empty_hash ->
        {block_number, nil, nil}

      {_block_number, _block_hash, hash} ->
        {block_number_by_hash(hash, json_rpc_named_arguments) || 0, nil, nil}
    end
  end

  @doc false
  # Checks the checkpoint against the chain of the L1 node before the fetcher handles any chunk, and returns the state
  # to take up with. An L1 node returns a block by its hash also when the block is off its chain, so the checkpoint is
  # checked by its number. Its block can go off the chain in an L1 reorg while the fetcher is down, unseen by the reorg
  # monitor: the deposits are then derived again from before it, as after a reorg reported at it (see `rewind/3`).
  #
  # A fetcher of the previous version writes only the hash, also when it rewinds after a reorg (to an earlier block,
  # or to none, removing the rows after it), while a deployment rolls over or after a rollback. When the hash under the
  # previous name is not the hash of the checkpoint, the fetcher takes up as the previous version does: after the block
  # of that hash if it is on the chain, from before it if not, and from the start block if the node does not find it.
  @spec check_checkpoint(map()) :: map()
  def check_checkpoint(%{start_block_l1: start_block_l1, json_rpc_named_arguments: json_rpc_named_arguments} = state) do
    {block_number, hash} =
      case read_checkpoint() do
        {block_number, block_hash, block_hash} when block_number > 0 and block_hash != @empty_hash ->
          {block_number, block_hash}

        {_block_number, _block_hash, hash} ->
          {block_number_by_hash(hash, json_rpc_named_arguments), hash}
      end

    cond do
      is_nil(block_number) ->
        %{state | start_block: start_block_l1}

      on_chain?(block_number, hash, json_rpc_named_arguments) ->
        %{state | start_block: max(start_block_l1, block_number)}

      true ->
        Logger.warning(
          "The checkpoint block #{block_number} (#{hash}) is not on the chain of the L1 node: the L1 chain was reorganized, or the node lags behind. Deriving the deposits again from before it..."
        )

        %{state | start_block: rewind(block_number, block_number, state) + 1}
    end
  end

  # The checkpoint, read in one query: the number and the hash of its block, and the hash under the previous name.
  # Without a checkpoint, the number is 0 and the hashes are the empty hash.
  defp read_checkpoint do
    values = Map.new(LastFetchedCounter.get_multiple([@counter_type_block, @counter_type]))
    value = &Decimal.to_integer(Map.get(values, &1) || Decimal.new(0))
    to_hash = &("0x" <> (&1 |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")))
    block = value.(@counter_type_block)

    {div(block, @hash_values), to_hash.(rem(block, @hash_values)), to_hash.(value.(@counter_type))}
  end

  defp on_chain?(block_number, block_hash, json_rpc_named_arguments) do
    case Optimism.get_block_by_number(block_number, json_rpc_named_arguments) do
      {:ok, %{"hash" => hash}} -> String.downcase(hash) == block_hash
      {:ok, nil} -> false
    end
  end

  # The number of the block the L1 node returns by the hash, on its chain or not, or nil
  defp block_number_by_hash(@empty_hash, _json_rpc_named_arguments), do: nil

  defp block_number_by_hash(block_hash, json_rpc_named_arguments) do
    case Optimism.get_block_by_hash(block_hash, json_rpc_named_arguments) do
      {:ok, %{"number" => number}} -> quantity_to_integer(number)
      {:ok, nil} -> nil
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
