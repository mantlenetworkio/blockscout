defmodule Indexer.Fetcher.Optimism.TransactionBatch do
  @moduledoc """
    Fills op_transaction_batches, op_frame_sequence, and op_frame_sequence_blobs DB tables.

    This module parses L1 batch transactions, handles them to retrieve L2 block batches info
    and save it to the database.

    If an L1 transaction is a blob transaction (either EIP-4844, Celestia, etc.), the blob
    is read from the corresponding server by its API URL and parsed to get raw data. Blob
    metadata is saved to op_frame_sequence_blobs DB table.

    According to EIP-4844, an L1 transaction can have more than one blob. Each EIP-4844 blob
    contains a separate frame (part of a frame sequence that encodes a batch), so usually
    L1 EIP-4844 transaction represents a frame sequence.

    Celestia L1 transaction can have only one blob. A batch can be split into several Celestia blobs
    related to different L1 transactions (usually following each other).
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  import EthereumJSONRPC, only: [fetch_blocks_by_range: 2, json_rpc: 2, quantity_to_integer: 1]

  import Explorer.Helper, only: [hash_to_binary: 1, parse_integer: 1]

  alias Ecto.Multi
  alias EthereumJSONRPC.Block.{ByHash, ByNumber}
  alias EthereumJSONRPC.{Blocks, Contract}
  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.{Block, Hash}
  alias Explorer.Chain.Events.Publisher
  alias Explorer.Chain.Optimism.{FrameSequence, FrameSequenceBlob}
  alias Explorer.Chain.Optimism.TransactionBatch, as: OptimismTransactionBatch
  alias Indexer.Fetcher.{Optimism, RollupL1ReorgMonitor}
  alias Indexer.Fetcher.Optimism.{BatcherTimeline, BlobRetryQueue}
  alias Indexer.Helper
  alias Indexer.Prometheus.Instrumenter
  alias Indexer.RollupReorgMonitorQueue
  alias Varint.LEB128

  @fetcher_name :optimism_transaction_batches

  @compressor_brotli 1
  # the max number of L2 blocks in one batch request checking span batches
  @l2_blocks_request_size 50
  # how many times, and how many milliseconds apart, the parent of a batch is asked for while the L2 node answers
  # without it (missing, or not safe yet for a span batch): up to 15 minutes
  @parent_check_attempts 180
  @parent_check_interval 5_000
  @counter_type "optimism_batches_fetcher_last_l1_block_hash"
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
  def init(args) do
    {:ok, %{json_rpc_named_arguments_l2: args[:json_rpc_named_arguments]}, {:continue, nil}}
  end

  @impl GenServer
  def handle_continue(_, state) do
    Logger.metadata(fetcher: @fetcher_name)
    # two seconds pause needed to avoid exceeding Supervisor restart intensity when DB issues
    Process.send_after(self(), :init_with_delay, 2000)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        :init_with_delay,
        %{json_rpc_named_arguments_l2: json_rpc_named_arguments_l2} = state
      ) do
    env = Application.get_all_env(:indexer)[__MODULE__]

    optimism_env = Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism]
    system_config = optimism_env[:optimism_l1_system_config]
    optimism_l1_rpc = l1_rpc_url()

    with {:system_config_valid, true} <-
           {:system_config_valid, Helper.address_correct?(system_config)},
         {:genesis_block_l2_invalid, false} <-
           {:genesis_block_l2_invalid, is_nil(env[:genesis_block_l2]) or env[:genesis_block_l2] < 0},
         _ <- RollupL1ReorgMonitor.wait_for_start(__MODULE__),
         {:rpc_l1_undefined, false} <- {:rpc_l1_undefined, is_nil(optimism_l1_rpc)},
         json_rpc_named_arguments = Helper.json_rpc_named_arguments(optimism_l1_rpc),
         {:system_config_read, {rollup_start_block_l1, batch_inbox}} <-
           {:system_config_read, read_system_config(system_config, json_rpc_named_arguments)},
         # the first L1 blocks of a rollup can carry batches in a format this module cannot read
         start_block_l1 = env[:start_block] || rollup_start_block_l1,
         {:batch_inbox_valid, true} <- {:batch_inbox_valid, Helper.address_correct?(batch_inbox)},
         true <- start_block_l1 > 0,
         chunk_size = parse_integer(env[:blocks_chunk_size]),
         {:chunk_size_valid, true} <- {:chunk_size_valid, !is_nil(chunk_size) && chunk_size > 0},
         {:block_duration_valid, true} <- {:block_duration_valid, optimism_env[:block_duration] > 0},
         {:ok, genesis_time_offset} <-
           genesis_time_offset(env[:genesis_block_l2], env[:genesis_l2_time], json_rpc_named_arguments_l2),
         {last_l1_block_number, last_l1_transaction_hash, last_l1_transaction} =
           get_last_l1_item(json_rpc_named_arguments),
         # INDEXER_OPTIMISM_L1_BATCH_START_BLOCK above the last processed block makes the scan skip ahead
         {:start_block_l1_valid, true} <-
           {:start_block_l1_valid, rollup_start_block_l1 <= last_l1_block_number || last_l1_block_number == 0},
         {:l1_transaction_not_found, false} <-
           {:l1_transaction_not_found, !is_nil(last_l1_transaction_hash) && is_nil(last_l1_transaction)},
         {:ok, block_check_interval, last_safe_block} <-
           Helper.get_block_check_interval(json_rpc_named_arguments),
         {:batcher_timeline, {:ok, batcher_timeline}} <-
           {:batcher_timeline,
            BatcherTimeline.init(
              system_config,
              start_block_l1,
              env[:submitter],
              env[:submitter_updates_range_size],
              json_rpc_named_arguments,
              # after a restart, the batcher updates are read from where the processing resumes
              from: max(start_block_l1, last_l1_block_number)
            )} do
      start_block = max(start_block_l1, last_l1_block_number)

      chain_id_l1 =
        case EthereumJSONRPC.fetch_chain_id(json_rpc_named_arguments) do
          {:ok, id} ->
            id

          {:error, reason} ->
            Logger.warning(
              "Cannot get Chain ID from L1 RPC. Reason: #{inspect(reason)}. The module will use fallback values from INDEXER_BEACON_BLOB_FETCHER_* env variables."
            )

            nil
        end

      Process.send(self(), :continue, [])

      {:noreply,
       %{
         batch_inbox: batch_inbox,
         batcher_timeline: batcher_timeline,
         eip4844_blobs_api_url: Helper.trim_url(env[:eip4844_blobs_api_url]),
         eip4844_blobs_api_fallback_url: Helper.trim_url(env[:eip4844_blobs_api_fallback_url]),
         celestia_blobs_api_url: Helper.trim_url(env[:celestia_blobs_api_url]),
         eigenda_blobs_api_url: Helper.trim_url(env[:eigenda_blobs_api_url]),
         alt_da_server_url: Helper.trim_url(env[:alt_da_server_url]),
         block_check_interval: block_check_interval,
         start_block: start_block,
         end_block: last_safe_block,
         chunk_size: chunk_size,
         incomplete_channels: %{},
         genesis_block_l2: env[:genesis_block_l2],
         block_duration: optimism_env[:block_duration],
         genesis_time_offset: genesis_time_offset,
         json_rpc_named_arguments: json_rpc_named_arguments,
         json_rpc_named_arguments_l2: json_rpc_named_arguments_l2,
         chain_id_l1: chain_id_l1
       }}
    else
      {:system_config_valid, false} ->
        Logger.error("SystemConfig contract address is invalid or undefined.")
        {:stop, :normal, state}

      {:genesis_block_l2_invalid, true} ->
        Logger.error("L2 genesis block number is undefined or invalid.")
        {:stop, :normal, state}

      {:rpc_l1_undefined, true} ->
        Logger.error("L1 RPC URL is not defined.")
        {:stop, :normal, state}

      {:batch_inbox_valid, false} ->
        Logger.error("Batch Inbox address is invalid or not defined.")
        {:stop, :normal, state}

      {:batcher_timeline, {:error, reason}} ->
        Logger.error(reason)
        {:stop, :normal, state}

      {:start_block_l1_valid, false} ->
        Logger.error("Invalid L1 Start Block value. Please, check the value and op_transaction_batches table.")

        {:stop, :normal, state}

      {:chunk_size_valid, false} ->
        Logger.error("Invalid blocks chunk size value.")
        {:stop, :normal, state}

      {:block_duration_valid, false} ->
        Logger.error("Check INDEXER_OPTIMISM_BLOCK_DURATION env variable. Its value must be a positive integer.")
        {:stop, :normal, state}

      {:error, error_data} ->
        Logger.error("Cannot get block timestamp by its number due to RPC error: #{inspect(error_data)}")

        {:stop, :normal, state}

      {:l1_transaction_not_found, true} ->
        Logger.error(
          "Cannot find last L1 transaction from RPC by its hash. Probably, there was a reorg on L1 chain. Please, check op_transaction_batches table."
        )

        {:stop, :normal, state}

      {:system_config_read, nil} ->
        Logger.error("Cannot read SystemConfig contract and fallback envs are not correctly defined.")
        {:stop, :normal, state}

      _ ->
        Logger.error("Batch Start Block is invalid or zero.")
        {:stop, :normal, state}
    end
  end

  # The main handler filtering L1 transactions and parsing them to retrieve
  # batches of L2 blocks.
  #
  # The work is split into chunks (L1 block subranges) of the specified block range.
  # The chunk size is configurable through INDEXER_OPTIMISM_L1_BATCH_BLOCKS_CHUNK_SIZE
  # env variable.
  #
  # When the last block of the range is reached, the handler switches to `(last+1)..latest`
  # block range and then handles the new blocks in realtime. The latest block number is checked
  # every `block_check_interval` milliseconds which is calculated in the init function.
  #
  # ## Parameters (in the `state` param)
  # - `batch_inbox`: L1 address which accepts L1 batch transactions
  # - `batcher_timeline`: `BatcherTimeline` with the L1 address authorized to send batch transactions
  #                       to the `batch_inbox` at each L1 block
  # - `eip4844_blobs_api_url`: URL of Blockscout Blobs API to get EIP-4844 blobs
  # - `celestia_blobs_api_url`: URL of the server where Celestia blobs can be read from
  # - `eigenda_blobs_api_url`: URL of the server where EigenDA blobs can be read from
  # - `alt_da_server_url`: URL of Alt-DA server where keccak commitment data can be read from
  # - `block_check_interval`: time interval for checking latest block number
  # - `start_block`: start block number of the block range
  # - `end_block`: end block number of the block range
  # - `chunk_size`: max number of L1 blocks in one chunk
  # - `incomplete_channels`: intermediate map of channels (incomplete frame sequences) in memory
  # - `genesis_block_l2`: Optimism BedRock upgrade L2 block number (used when parsing span batches)
  # - `block_duration`: L2 block duration in seconds (used when parsing span batches)
  # - `genesis_time_offset`: seconds from the rollup genesis time to the timestamp of the genesis block (used when
  #   parsing span batches)
  # - `json_rpc_named_arguments`: data to connect to L1 RPC server
  # - `json_rpc_named_arguments_l2`: data to connect to L2 RPC server
  # - `chain_id_l1`: chain ID of L1 layer.
  @impl GenServer
  def handle_info(
        :continue,
        %{
          batch_inbox: batch_inbox,
          batcher_timeline: batcher_timeline,
          eip4844_blobs_api_url: eip4844_blobs_api_url,
          eip4844_blobs_api_fallback_url: eip4844_blobs_api_fallback_url,
          celestia_blobs_api_url: celestia_blobs_api_url,
          eigenda_blobs_api_url: eigenda_blobs_api_url,
          alt_da_server_url: alt_da_server_url,
          block_check_interval: block_check_interval,
          start_block: start_block,
          end_block: end_block,
          chunk_size: chunk_size,
          incomplete_channels: incomplete_channels,
          genesis_block_l2: genesis_block_l2,
          block_duration: block_duration,
          genesis_time_offset: genesis_time_offset,
          json_rpc_named_arguments: json_rpc_named_arguments,
          json_rpc_named_arguments_l2: json_rpc_named_arguments_l2,
          chain_id_l1: chain_id_l1
        } = state
      ) do
    time_before = Timex.now()

    # If any previously-failed blob fetches are due for retry, rewind start_block
    # back to the earliest pending L1 block so the upcoming scan re-fetches those
    # blobs (da-indexer should have caught up by now in most cases).
    {start_block, retried_min_block} =
      case BlobRetryQueue.due_min_block() do
        nil ->
          {start_block, nil}

        retry_block when retry_block < start_block ->
          Logger.info(
            "BlobRetryQueue: retrying L1 block #{retry_block} (current head was #{start_block}). " <>
              "Pending queue size: #{BlobRetryQueue.size()}."
          )

          {retry_block, retry_block}

        _other ->
          # Retry block is ahead of current start_block — natural catchup will cover it
          {start_block, nil}
      end

    chunks_number = ceil((end_block - start_block + 1) / chunk_size)
    chunk_range = Range.new(0, max(chunks_number - 1, 0), 1)

    # Seed the parent_hash chain check with the last block hash we persisted on the previous
    # successful chunk. The check defends against L1 reorgs that `RollupL1ReorgMonitor` misses
    # (e.g. same-height reorgs where head number doesn't go down). When `BlobRetryQueue`
    # forced a rewind, the persisted hash is for a *later* block than our new `start_block`
    # and would false-positive, so we pass `@empty_hash` to skip the very first chunk's check.
    initial_prev_chunk_last_hash =
      if is_nil(retried_min_block) do
        Optimism.get_last_block_hash(@counter_type)
      else
        @empty_hash
      end

    {last_written_block, new_incomplete_channels, _final_prev_chunk_last_hash, new_batcher_timeline} =
      chunk_range
      |> Enum.reduce_while(
        {start_block - 1, incomplete_channels, initial_prev_chunk_last_hash, batcher_timeline},
        fn current_chunk, {_, incomplete_channels_acc, prev_chunk_last_hash, batcher_timeline_acc} ->
          chunk_start = start_block + chunk_size * current_chunk
          chunk_end = min(chunk_start + chunk_size - 1, end_block)
          # an empty chunk (the end block is below the start block, e.g. after a restart) keeps the position
          last_scanned_block = max(chunk_end, chunk_start - 1)

          {new_incomplete_channels, last_block_hash, new_batcher_timeline} =
            if chunk_end >= chunk_start do
              Helper.log_blocks_chunk_handling(
                chunk_start,
                chunk_end,
                start_block,
                end_block,
                nil,
                :L1
              )

              {:ok, new_incomplete_channels, batches, sequences, blobs, last_block_hash, new_batcher_timeline} =
                get_transaction_batches(
                  Range.new(chunk_start, chunk_end),
                  batch_inbox,
                  batcher_timeline_acc,
                  {genesis_block_l2, block_duration, genesis_time_offset},
                  incomplete_channels_acc,
                  {json_rpc_named_arguments, json_rpc_named_arguments_l2},
                  {eip4844_blobs_api_url, eip4844_blobs_api_fallback_url, celestia_blobs_api_url, eigenda_blobs_api_url,
                   alt_da_server_url, chain_id_l1},
                  prev_chunk_last_hash,
                  Helper.infinite_retries_number()
                )

              {batches, sequences, blobs} = remove_duplicates(batches, sequences, blobs)

              {:ok, _} =
                Chain.import(%{
                  optimism_frame_sequences: %{params: sequences},
                  timeout: :infinity
                })

              {:ok, inserted} =
                Chain.import(%{
                  optimism_frame_sequence_blobs: %{params: blobs},
                  optimism_transaction_batches: %{params: batches},
                  timeout: :infinity
                })

              removed_sequence_ids = remove_prev_frame_sequences(inserted)
              sequences = Enum.reject(sequences, fn s -> s.id in removed_sequence_ids end)
              set_frame_sequences_view_ready(sequences)

              last_batch =
                sequences
                |> Enum.max_by(& &1.id, fn -> nil end)

              # credo:disable-for-next-line
              if last_batch do
                Instrumenter.set_latest_batch(last_batch.id, last_batch.l1_timestamp)
              end

              Publisher.broadcast(
                %{
                  new_optimism_batches:
                    Enum.map(sequences, &FrameSequence.batch_by_number(&1.id, include_blobs?: false))
                },
                :realtime
              )

              Helper.log_blocks_chunk_handling(
                chunk_start,
                chunk_end,
                start_block,
                end_block,
                "#{Enum.count(sequences)} batch(es) containing #{Enum.count(batches)} block(s).",
                :L1
              )

              {new_incomplete_channels, last_block_hash, new_batcher_timeline}
            else
              {incomplete_channels_acc, nil, batcher_timeline_acc}
            end

          reorg_block = RollupReorgMonitorQueue.pop(__MODULE__)

          if !is_nil(reorg_block) && reorg_block > 0 do
            new_incomplete_channels = handle_l1_reorg(reorg_block, new_incomplete_channels)

            Optimism.set_last_block_hash(@empty_hash, @counter_type)

            last_kept_block = min(reorg_block - 1, last_scanned_block)

            # the reorg can start below `reorg_block`: the timeline keeps the hashes up to the last kept block,
            # so the next chunk must extend them, or all unfinalized blocks are processed again
            {:halt,
             {last_kept_block, new_incomplete_channels, @empty_hash,
              BatcherTimeline.truncate(new_batcher_timeline, last_kept_block)}}
          else
            Optimism.set_last_block_hash(last_block_hash, @counter_type)

            {:cont,
             {last_scanned_block, new_incomplete_channels, last_block_hash || prev_chunk_last_hash,
              new_batcher_timeline}}
          end
        end
      )

    new_start_block = last_written_block + 1
    new_end_block = Helper.fetch_latest_l1_block_number(json_rpc_named_arguments)

    # If we rewound for blob retries, mark the rescanned range as attempted so
    # the queue can advance backoff / drop entries that exceeded max attempts.
    if retried_min_block do
      BlobRetryQueue.mark_range_attempted(retried_min_block, last_written_block)
    end

    delay =
      if new_end_block <= last_written_block do
        # there is no new block, so wait for some time to let the chain issue the new block
        max(block_check_interval - Timex.diff(Timex.now(), time_before, :milliseconds), 0)
      else
        0
      end

    Process.send_after(self(), :continue, delay)

    {:noreply,
     %{
       state
       | start_block: new_start_block,
         end_block: new_end_block,
         incomplete_channels: new_incomplete_channels,
         batcher_timeline: new_batcher_timeline
     }}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @doc false
  # Returns a `hash -> number` map of the given L2 blocks, from the database or from the L2 node, without the blocks
  # the node does not return, or `:unavailable` when the node does not answer.
  def get_block_numbers_by_hashes([], _json_rpc_named_arguments_l2) do
    %{}
  end

  def get_block_numbers_by_hashes(hashes, json_rpc_named_arguments_l2) do
    query =
      from(
        b in Block,
        select: {b.hash, b.number},
        where: b.hash in ^hashes
      )

    number_by_hash =
      query
      |> Repo.all(timeout: :infinity)
      |> Enum.reduce(%{}, fn {hash, number}, acc ->
        Map.put(acc, hash.bytes, number)
      end)

    hashes
    |> Enum.filter(fn hash -> is_nil(Map.get(number_by_hash, hash)) end)
    |> Enum.with_index()
    |> Enum.map(fn {hash, id} ->
      {:ok, hash} = Hash.Full.cast(hash)
      ByHash.request(%{hash: hash, id: id}, false)
    end)
    |> Enum.chunk_every(50)
    |> Enum.reduce_while(number_by_hash, fn requests, acc ->
      case json_rpc(requests, json_rpc_named_arguments_l2) do
        {:ok, responses} ->
          {:cont,
           Enum.reduce(responses, acc, fn
             %{result: %{"number" => number, "hash" => "0x" <> hash}}, acc ->
               Map.put(acc, Base.decode16!(hash, case: :mixed), quantity_to_integer(number))

             # a block the node does not return (yet)
             _, acc ->
               acc
           end)}

        {:error, _} ->
          {:halt, :unavailable}
      end
    end)
  end

  defp get_block_hash_by_number(block_number, blocks_params) do
    block = Enum.find(blocks_params, %{hash: nil}, fn b -> b.number == block_number end)
    block.hash
  end

  defp get_block_timestamp_by_number(block_number, blocks_params) do
    block = Enum.find(blocks_params, %{timestamp: nil}, fn b -> b.number == block_number end)
    block.timestamp
  end

  # Determines the last saved L1 block number, the last saved transaction hash, and the transaction info for batches.
  #
  # Utilized to start fetching from a correct block number after reorg has occurred.
  #
  # ## Parameters
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  #                               Used to get transaction info by its hash from the RPC node.
  #
  # ## Returns
  # - A tuple `{last_block_number, last_transaction_hash, last_transaction}` where
  #   `last_block_number` is the last block number found in the corresponding table (0 if not found),
  #   `last_transaction_hash` is the last transaction hash found in the corresponding table (nil if not found),
  #   `last_transaction` is the transaction info got from the RPC (nil if not found).
  @spec get_last_l1_item(EthereumJSONRPC.json_rpc_named_arguments()) :: {non_neg_integer(), binary() | nil, map() | nil}
  defp get_last_l1_item(json_rpc_named_arguments) do
    last_l1_block_number =
      Optimism.get_last_block_number_from_last_fetched_counter(json_rpc_named_arguments, @counter_type)

    if is_nil(last_l1_block_number) do
      result =
        Repo.one(
          from(
            tb in OptimismTransactionBatch,
            inner_join: fs in FrameSequence,
            on: fs.id == tb.frame_sequence_id,
            select: {fs.id, fs.l1_transaction_hashes},
            order_by: [desc: tb.l2_block_number],
            limit: 1
          )
        )

      with {:empty_hashes, false} <- {:empty_hashes, is_nil(result)},
           l1_transaction_hashes = elem(result, 1),
           last_l1_transaction_hash = List.last(l1_transaction_hashes),
           {:ok, last_l1_transaction} =
             Helper.get_transaction_by_hash(last_l1_transaction_hash, json_rpc_named_arguments),
           {:empty_transaction, false, last_l1_transaction_hash} <-
             {:empty_transaction, is_nil(last_l1_transaction), last_l1_transaction_hash} do
        last_l1_block_number = quantity_to_integer(Map.get(last_l1_transaction, "blockNumber", 0))
        {last_l1_block_number, last_l1_transaction_hash, last_l1_transaction}
      else
        {:empty_hashes, true} ->
          {0, nil, nil}

        {:empty_transaction, true, last_l1_transaction_hash} ->
          Logger.error(
            "Cannot find last L1 transaction from RPC by its hash (#{last_l1_transaction_hash}). Probably, there was a reorg on L1 chain. Trying to check preceding frame sequence..."
          )

          id = elem(result, 0)

          Multi.new()
          |> Multi.delete_all(
            :delete_transaction_batches,
            from(tb in OptimismTransactionBatch, where: tb.frame_sequence_id == ^id)
          )
          |> Multi.delete_all(:delete_frame_sequence, from(fs in FrameSequence, where: fs.id == ^id))
          |> Repo.transaction()

          get_last_l1_item(json_rpc_named_arguments)
      end
    else
      {last_l1_block_number, nil, nil}
    end
  end

  defp get_transaction_batches(
         block_range,
         batch_inbox,
         batcher_timeline,
         span_batch_params,
         incomplete_channels,
         {json_rpc_named_arguments, json_rpc_named_arguments_l2},
         blobs_api_url,
         prev_chunk_last_hash,
         retries_left
       ) do
    case fetch_blocks_by_range(block_range, json_rpc_named_arguments) do
      {:ok, %Blocks{transactions_params: transactions_params, blocks_params: blocks_params, errors: []}} ->
        chunk_start = Enum.min(block_range)

        last_block_hash =
          block_range
          |> Enum.max()
          |> get_block_hash_by_number(blocks_params)

        case validate_chain_continuity(chunk_start, blocks_params, prev_chunk_last_hash) do
          :ok ->
            with {:ok, new_batcher_timeline} <-
                   BatcherTimeline.sync(batcher_timeline, blocks_params, json_rpc_named_arguments),
                 transactions_filtered = transactions_filter(transactions_params, new_batcher_timeline, batch_inbox),
                 :ok <- validate_eip4844_blob_hashes(transactions_filtered) do
              transactions_filtered
              |> get_transaction_batches_inner(
                blocks_params,
                span_batch_params,
                incomplete_channels,
                json_rpc_named_arguments_l2,
                blobs_api_url
              )
              |> (&Tuple.insert_at(&1, tuple_size(&1), last_block_hash)).()
              |> (&Tuple.insert_at(&1, tuple_size(&1), new_batcher_timeline)).()
            else
              {:reorg, divergence_block} ->
                # the chunk is on another fork than the blocks whose batcher updates were read before
                RollupReorgMonitorQueue.push(divergence_block, __MODULE__)
                {:ok, incomplete_channels, [], [], [], last_block_hash, batcher_timeline}

              {:error, message} ->
                retry_get_transaction_batches(
                  block_range,
                  batch_inbox,
                  batcher_timeline,
                  span_batch_params,
                  incomplete_channels,
                  {json_rpc_named_arguments, json_rpc_named_arguments_l2},
                  blobs_api_url,
                  prev_chunk_last_hash,
                  retries_left,
                  message
                )
            end

          {:reorg, divergence_block} ->
            Logger.warning(
              "L1 reorg detected by chain-continuity check at L1 block ##{chunk_start}: " <>
                "stored last_block_hash=#{prev_chunk_last_hash} matches neither the hash nor the parent_hash " <>
                "of block ##{chunk_start}. Rewinding to ##{divergence_block} via RollupReorgMonitorQueue."
            )

            RollupReorgMonitorQueue.push(divergence_block, __MODULE__)

            # Return empty results so the caller's Chain.import calls are no-ops; the very next
            # `RollupReorgMonitorQueue.pop(__MODULE__)` will surface our pushed divergence_block
            # and the existing :halt branch will rewind + reset last_block_hash. The returned
            # `last_block_hash` is therefore inconsequential — pick the chunk's tail to keep the
            # tuple shape consistent.
            {:ok, incomplete_channels, [], [], [], last_block_hash, batcher_timeline}
        end

      {_, message_or_errors} ->
        message =
          case message_or_errors do
            %Blocks{errors: errors} -> errors
            msg -> msg
          end

        retry_get_transaction_batches(
          block_range,
          batch_inbox,
          batcher_timeline,
          span_batch_params,
          incomplete_channels,
          {json_rpc_named_arguments, json_rpc_named_arguments_l2},
          blobs_api_url,
          prev_chunk_last_hash,
          retries_left,
          message
        )
    end
  end

  defp retry_get_transaction_batches(
         block_range,
         batch_inbox,
         batcher_timeline,
         span_batch_params,
         incomplete_channels,
         {json_rpc_named_arguments, json_rpc_named_arguments_l2},
         blobs_api_url,
         prev_chunk_last_hash,
         retries_left,
         message
       ) do
    retries_left = retries_left - 1

    error_message = "Cannot fetch blocks #{inspect(block_range)}. Error(s): #{inspect(message)}"

    if retries_left <= 0 do
      Logger.error(error_message)
      {:error, message}
    else
      Optimism.log_error_message_with_retry_sleep(error_message)

      get_transaction_batches(
        block_range,
        batch_inbox,
        batcher_timeline,
        span_batch_params,
        incomplete_channels,
        {json_rpc_named_arguments, json_rpc_named_arguments_l2},
        blobs_api_url,
        prev_chunk_last_hash,
        retries_left
      )
    end
  end

  @doc """
  Validates that the chunk we just fetched is still rooted in the L1 chain we last persisted.

  This is the second-line defense against L1 reorgs that `RollupL1ReorgMonitor` cannot detect
  because they don't reduce the latest block number (e.g. a same-height hash flip on the head
  block).

  The check accepts the chunk as continuous when either of the two valid relationships holds
  between the persisted `expected_hash` (= the hash of the last block of the last fully-processed
  chunk, written by `Optimism.set_last_block_hash/2`) and the first block of the new chunk:

  1. **Forward step**: `block(chunk_start).parent_hash == expected_hash`. The normal in-process
     case where `start_block = last_chunk_end + 1`.
  2. **Boundary re-scan**: `block(chunk_start).hash == expected_hash`. The post-restart case
     where `handle_continue` seeds `start_block = max(start_block_l1, last_l1_block_number)`
     (note: not +1, so the very first chunk re-scans the persisted tail block).

  If **neither** relationship holds the canonical L1 chain has diverged at or before
  `chunk_start`, and we surface a `:reorg`.

  ## Parameters
  - `chunk_start`: The smallest L1 block number in the upcoming chunk.
  - `blocks_params`: The list of `EthereumJSONRPC.Block.params` we just fetched for this chunk.
  - `expected_hash`: The hash we last persisted in the OP counter. `nil` or the all-zero
    `@empty_hash` skips the check (initial start, post-reorg reset, or `BlobRetryQueue` rewind
    seeded the accumulator with `@empty_hash`).

  ## Returns
  - `:ok` — chain is continuous, or check was skipped because no expected hash was provided.
  - `{:reorg, divergence_block}` — mismatch; `divergence_block` is the block at or before which
    the reorg occurred (conservatively `chunk_start - 1`, clamped to 0). Caller should rewind.
  """
  @spec validate_chain_continuity(non_neg_integer(), [map()], binary() | nil) ::
          :ok | {:reorg, non_neg_integer()}
  def validate_chain_continuity(_chunk_start, _blocks_params, nil), do: :ok
  def validate_chain_continuity(_chunk_start, _blocks_params, @empty_hash), do: :ok

  def validate_chain_continuity(chunk_start, blocks_params, expected_hash) when is_binary(expected_hash) do
    case get_block_by_number(chunk_start, blocks_params) do
      nil ->
        # Block missing from the fetched response — shouldn't happen for a chunk we just
        # successfully fetched. Be defensive: treat as :ok rather than false-positive.
        :ok

      block ->
        expected_down = String.downcase(expected_hash)
        block_hash = block |> Map.get(:hash, "") |> to_string() |> String.downcase()
        parent_hash = block |> Map.get(:parent_hash, "") |> to_string() |> String.downcase()

        cond do
          # Boundary re-scan: this chunk starts at the very block whose hash we persisted.
          # Common right after pod restart, when `start_block` is seeded to `last_l1_block_number`
          # (not +1). The persisted block is still canonical, so the chain is continuous.
          block_hash != "" and block_hash == expected_down ->
            :ok

          # Forward step: the chunk starts at last_chunk_end + 1, so its parent IS the block we
          # last persisted. Standard in-process tick.
          parent_hash != "" and parent_hash == expected_down ->
            :ok

          true ->
            {:reorg, max(chunk_start - 1, 0)}
        end
    end
  end

  defp get_block_by_number(block_number, blocks_params) do
    Enum.find(blocks_params, fn b -> b.number == block_number end)
  end

  # Tries to resolve each blob through a three-layer chain:
  #   1. Primary URL (`INDEXER_OPTIMISM_L1_BATCH_BLOCKSCOUT_BLOBS_API_URL`)
  #   2. Fallback URL (`INDEXER_OPTIMISM_L1_BATCH_BLOBS_API_FALLBACK_URL`), optional
  #   3. Beacon Node `/blob_sidecars/` endpoint (`INDEXER_BEACON_RPC_URL`)
  #
  # Both Primary and Fallback URLs accept either the Blockscout Blobs API format
  # (`{url}/{hash}` returning `{"blob_data": "0x..."}`) or the Mantle DA Indexer
  # format (`{url}/eth/v1/beacon/blobs/{slot}?versioned_hashes={hash}` returning
  # `{"data": ["0x..."]}`). Detection is based on the URL path.
  defp eip4844_blobs_to_inputs(
         transaction_hash,
         l1_block_number,
         blob_versioned_hashes,
         block_timestamp,
         primary_api_url,
         fallback_api_url,
         chain_id_l1
       ) do
    blob_versioned_hashes
    |> Enum.reduce([], fn blob_hash, inputs_acc ->
      resolve_eip4844_blob(
        transaction_hash,
        l1_block_number,
        blob_hash,
        block_timestamp,
        primary_api_url,
        fallback_api_url,
        chain_id_l1,
        inputs_acc
      )
    end)
    |> Enum.reverse()
  end

  @doc false
  # Mantle's batcher, before Arsia, joined the data of a transaction's blobs and RLP-encoded the frame data it carried
  # as a list. Mantle's op-node tries that layout first (`MantleBlobDataSource`) and falls back to the standard one,
  # where the data of each blob is frame data, until the first standard blob after Arsia, from which it takes every
  # blob as a standard one. So does this function, for the transactions before INDEXER_OPTIMISM_L1_BATCH_MANTLE_BLOBS_END_BLOCK
  # (the L1 block of that first standard blob; unset, it never tries the Mantle layout). It decodes the joined data
  # only when every blob of the transaction is at hand (a missing one is fetched again later, see `BlobRetryQueue`),
  # and only as a whole list of byte strings, as op-node does. Each piece of frame data keeps the hashes of all the
  # blobs it was joined from.
  @spec unwrap_mantle_blob_inputs([map()], [String.t()], non_neg_integer()) :: [map()]
  def unwrap_mantle_blob_inputs(inputs, blob_versioned_hashes, l1_block_number) do
    mantle_blobs_end_block = Application.get_all_env(:indexer)[__MODULE__][:mantle_blobs_end_block]

    with true <- not is_nil(mantle_blobs_end_block) and l1_block_number < mantle_blobs_end_block,
         true <- inputs != [] and length(inputs) == length(blob_versioned_hashes),
         {:ok, frame_data} <- decode_rlp_byte_strings(Enum.map_join(inputs, & &1.bytes)) do
      blob_hashes = Enum.map(inputs, & &1.eip4844_blob_hash)

      Enum.map(
        frame_data,
        &%{bytes: &1, eip4844_blob_hash: List.first(blob_hashes), eip4844_blob_hashes: blob_hashes}
      )
    else
      _ -> inputs
    end
  end

  # Decodes `data` as one RLP list of byte strings with nothing after it, as Go's `rlp.DecodeBytes` does: the list must
  # encode back to `data` exactly. (`ExRLP.decode/1` reads data following an item as more list items, and its stream
  # mode returns list items in reverse.)
  defp decode_rlp_byte_strings(data) do
    list = ExRLP.decode(data)

    if is_list(list) and Enum.all?(list, &is_binary/1) and ExRLP.encode(list) == data,
      do: {:ok, list},
      else: :error
  rescue
    _ -> :error
  end

  @doc false
  @spec eip4844_blob_api_sources(String.t(), String.t()) :: [{String.t(), String.t()}]
  def eip4844_blob_api_sources(primary_api_url, fallback_api_url) do
    [
      {"Primary Blobs API", primary_api_url},
      {"Fallback Blobs API", fallback_api_url}
    ]
    |> Enum.reject(fn {_source_label, url} -> url == "" end)
    |> Enum.map(fn {source_label, url} -> {"#{source_label} (#{url})", url} end)
  end

  @doc false
  @spec log_eip4844_blob_source_failure(String.t(), String.t(), any()) :: :ok
  def log_eip4844_blob_source_failure(source_label, blob_hash, reason) do
    Logger.info(
      "#{source_label} failed for blob #{blob_hash}; trying next EIP-4844 blob source. " <>
        "Reason: #{inspect(reason, limit: 200)}"
    )
  end

  # Walks the Primary → Fallback (Blockscout API) → Beacon Sidecar chain for a single blob hash.
  @spec resolve_eip4844_blob(
          String.t(),
          non_neg_integer(),
          String.t(),
          DateTime.t(),
          String.t(),
          String.t(),
          non_neg_integer() | nil,
          [map()]
        ) :: [map()]
  defp resolve_eip4844_blob(
         transaction_hash,
         l1_block_number,
         blob_hash,
         block_timestamp,
         primary_api_url,
         fallback_api_url,
         chain_id_l1,
         inputs_acc
       ) do
    sources = eip4844_blob_api_sources(primary_api_url, fallback_api_url)

    decoded =
      Enum.reduce_while(sources, nil, fn {source_label, url}, _acc ->
        case fetch_blob_from_blobs_api(blob_hash, block_timestamp, url, chain_id_l1) do
          {:ok, raw_blob} ->
            case OptimismTransactionBatch.decode_eip4844_blob(raw_blob) do
              nil ->
                Logger.warning("Cannot decode the blob #{blob_hash} taken from the #{source_label}.")
                {:cont, nil}

              decoded_blob ->
                Logger.info(
                  "The input for transaction #{transaction_hash} is taken from the #{source_label}. Blob hash: #{blob_hash}"
                )

                BlobRetryQueue.mark_blob_succeeded(l1_block_number, blob_hash)
                {:halt, decoded_blob}
            end

          {:error, reason} ->
            log_eip4844_blob_source_failure(source_label, blob_hash, reason)
            {:cont, nil}
        end
      end)

    case decoded do
      nil ->
        # All blobs APIs exhausted — final fallback is Beacon Node `/blob_sidecars/`.
        eip4844_blobs_to_inputs_from_sidecars(
          transaction_hash,
          l1_block_number,
          blob_hash,
          block_timestamp,
          inputs_acc,
          chain_id_l1
        )

      bytes ->
        [%{bytes: bytes, eip4844_blob_hash: blob_hash} | inputs_acc]
    end
  end

  # Fetches a raw EIP-4844 blob from a Blobs API URL.
  # Supports two URL formats (auto-detected by path):
  #   1. Blockscout Blobs API — `{url}/{blob_hash}` → `{"blob_data": "0x..."}`
  #   2. Mantle DA Indexer (or any Beacon-compatible `/blobs/` endpoint) —
  #      `{url}/eth/v1/beacon/blobs/{slot}?versioned_hashes={blob_hash}` → `{"data": ["0x..."]}`
  #
  # Returns `{:ok, raw_blob_bytes}` on success or `{:error, reason}` on failure (including empty URL).
  @spec fetch_blob_from_blobs_api(String.t(), DateTime.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, binary()} | {:error, any()}
  defp fetch_blob_from_blobs_api(_blob_hash, _block_timestamp, "", _chain_id_l1), do: {:error, :empty_url}

  defp fetch_blob_from_blobs_api(blob_hash, block_timestamp, blobs_api_url, chain_id_l1) do
    if da_indexer_blobs_url?(blobs_api_url) do
      base_url = String.replace_suffix(blobs_api_url, "/eth/v1/beacon/blobs", "")

      Helper.get_eip4844_blob_from_indexer_result(base_url, blob_hash, block_timestamp, chain_id_l1)
    else
      with {:ok, response} <- Helper.http_get_request(blobs_api_url <> "/" <> blob_hash),
           blob_data when not is_nil(blob_data) <- Map.get(response, "blob_data") do
        {:ok, hash_to_binary(blob_data)}
      else
        {:error, reason} -> {:error, reason}
        nil -> {:error, :missing_blob_data}
        other -> {:error, {:unexpected_response, other}}
      end
    end
  end

  # Returns `true` if the URL targets a DA-indexer-style `/eth/v1/beacon/blobs` endpoint.
  @spec da_indexer_blobs_url?(String.t()) :: boolean()
  defp da_indexer_blobs_url?(url), do: String.contains?(url, "/eth/v1/beacon/blobs")

  # Final fallback — fetches the blob via the standard Beacon Node `/blob_sidecars/` endpoint.
  defp eip4844_blobs_to_inputs_from_sidecars(
         transaction_hash,
         l1_block_number,
         blob_hash,
         block_timestamp,
         inputs_acc,
         chain_id_l1
       ) do
    blob = Helper.get_eip4844_blob_from_beacon_node(blob_hash, block_timestamp, chain_id_l1)

    with false <- is_nil(blob),
         decoded_blob_data = OptimismTransactionBatch.decode_eip4844_blob(blob),
         {:blob_data_invalid, false} <- {:blob_data_invalid, is_nil(decoded_blob_data)} do
      Logger.info(
        "The input for transaction #{transaction_hash} is taken from the Beacon Node blob_sidecars. Blob hash: #{blob_hash}"
      )

      input = %{
        bytes: decoded_blob_data,
        eip4844_blob_hash: blob_hash
      }

      BlobRetryQueue.mark_blob_succeeded(l1_block_number, blob_hash)
      [input | inputs_acc]
    else
      true ->
        # All 3 layers exhausted. Most common cause on Mantle Hoodi: da-indexer
        # hasn't yet ingested this brand-new blob. Enqueue for later retry —
        # the main loop will rewind start_block to re-scan this L1 block once
        # the backoff window elapses.
        Logger.warning(
          "BLOB ALL-SOURCES EXHAUSTED — L1 block #{l1_block_number}, tx #{transaction_hash}, " <>
            "blob hash #{blob_hash}. Enqueued for retry."
        )

        BlobRetryQueue.enqueue(l1_block_number, blob_hash, transaction_hash)
        inputs_acc

      {:blob_data_invalid, true} ->
        Logger.warning("Cannot decode invalid blob #{blob_hash} taken from the Beacon Node.")
        inputs_acc
    end
  end

  # Gets Celestia blob data & metadata by L1 transaction input (encoding blob's height and commitment).
  # The data is read from the remote `da-indexer` service.
  #
  # ## Parameters
  # - `transaction_input`: The contents of transaction `input` field.
  # - `offset`: Offset (in bytes) within the `transaction_input` where blob's height is encoded.
  # - `transaction_hash`: The L1 transaction hash for logging purposes.
  # - `blobs_api_url`: The URL to `da-indexer` API.
  #
  # ## Returns
  # - A list with a map containing blob's data and metadata.
  # - An empty list in case of an error (`da-indexer` didn't respond, URL is not defined, or transaction input is incorrect).
  @spec celestia_blob_to_input(binary(), non_neg_integer(), String.t(), String.t()) :: [
          %{
            :bytes => binary(),
            :celestia_blob_metadata => %{
              :height => non_neg_integer(),
              :namespace => String.t(),
              :commitment => String.t()
            }
          }
        ]
  defp celestia_blob_to_input("0x" <> transaction_input, offset, transaction_hash, blobs_api_url) do
    transaction_input
    |> Base.decode16!(case: :mixed)
    |> celestia_blob_to_input(offset, transaction_hash, blobs_api_url)
  end

  defp celestia_blob_to_input(transaction_input, offset, _transaction_hash, blobs_api_url)
       when byte_size(transaction_input) == offset + 8 + 32 and blobs_api_url != "" do
    # 8 bytes after alt-da signature encode little-endian Celestia blob height
    height =
      transaction_input
      |> binary_part(offset, 8)
      |> :binary.decode_unsigned(:little)

    # the next 32 bytes contain the commitment
    commitment = binary_part(transaction_input, offset + 8, 32)
    commitment_string = Base.encode16(commitment, case: :lower)

    url = blobs_api_url <> "?height=#{height}&commitment=" <> commitment_string

    with {:ok, response} <- Helper.http_get_request(url),
         namespace = Map.get(response, "namespace"),
         data = Map.get(response, "data"),
         true <- !is_nil(namespace) and !is_nil(data) do
      data_decoded = Base.decode64!(data)

      [
        %{
          bytes: data_decoded,
          celestia_blob_metadata: %{
            height: height,
            namespace: "0x" <> namespace,
            commitment: "0x" <> commitment_string
          }
        }
      ]
    else
      false ->
        Logger.error("Cannot read namespace or data from Celestia Blobs API response for the request #{url}")

        []

      _ ->
        Logger.error("Cannot read a response from Celestia Blobs API for the request #{url}")
        []
    end
  end

  defp celestia_blob_to_input(_transaction_input, _offset, transaction_hash, blobs_api_url) when blobs_api_url != "" do
    Logger.error("L1 transaction with Celestia commitment has incorrect input length. Tx hash: #{transaction_hash}")

    []
  end

  defp celestia_blob_to_input(_transaction_input, _offset, _transaction_hash, "") do
    Logger.error(
      "Cannot read Celestia blobs from the server as the API URL is not defined. Please, check INDEXER_OPTIMISM_L1_BATCH_CELESTIA_BLOBS_API_URL env variable."
    )

    []
  end

  # Gets EigenDA blob data & metadata by L1 transaction input (encoding blob's certificate).
  # The data is read from the remote `da-indexer` service.
  #
  # ## Parameters
  # - `transaction_input`: The contents of transaction `input` field.
  # - `offset`: Offset (in bytes) within the `transaction_input` where blob's certificate is encoded.
  # - `transaction_hash`: The L1 transaction hash for logging purposes.
  # - `blobs_api_url`: The URL to `da-indexer` API.
  #
  # ## Returns
  # - A list with a map containing blob's data and certificate.
  # - An empty list in case of an error (`da-indexer` didn't respond, URL is not defined, or transaction input is incorrect).
  @spec eigenda_blob_to_input(binary(), non_neg_integer(), String.t(), String.t()) :: [
          %{:bytes => binary(), :eigenda_cert => binary()}
        ]
  defp eigenda_blob_to_input("0x" <> transaction_input, offset, transaction_hash, blobs_api_url) do
    transaction_input
    |> Base.decode16!(case: :mixed)
    |> eigenda_blob_to_input(offset, transaction_hash, blobs_api_url)
  end

  defp eigenda_blob_to_input(transaction_input, offset, transaction_hash, blobs_api_url) when blobs_api_url != "" do
    <<_::binary-size(offset), cert::binary>> = transaction_input

    url = blobs_api_url <> "/0x" <> Base.encode16(cert, case: :lower)

    url_with_proxy =
      case Application.get_all_env(:indexer)[__MODULE__][:eigenda_proxy_base_url] do
        nil ->
          url

        eigenda_proxy_base_url ->
          url <> "?proxyBaseUrl=" <> Helper.trim_url(eigenda_proxy_base_url)
      end

    with {:ok, response} <- Helper.http_get_request(url_with_proxy),
         data = Map.get(response, "data"),
         true <- !is_nil(data),
         data_binary = hash_to_binary(data),
         true <- byte_size(data_binary) > 0 do
      [
        %{
          bytes: data_binary,
          eigenda_cert: cert
        }
      ]
    else
      false ->
        Logger.error("EigenDA Proxy server response is empty for the request #{url_with_proxy}")

        []

      _ ->
        Logger.warning("Transaction hash: #{transaction_hash}")
        []
    end
  end

  defp eigenda_blob_to_input(_transaction_input, _offset, _transaction_hash, "") do
    Logger.error(
      "Cannot read EigenDA blobs from the server as the API URL is not defined. Please, check INDEXER_OPTIMISM_L1_BATCH_EIGENDA_BLOBS_API_URL env variable."
    )

    []
  end

  # Gets Alt-DA data & commitment hash by L1 transaction input (encoding the commitment).
  # The data is then read from the remote DA server.
  #
  # ## Parameters
  # - `transaction_input`: The contents of transaction `input` field.
  # - `transaction_hash`: The L1 transaction hash for logging purposes.
  # - `da_server_url`: The URL to DA server implementing a get request.
  #
  # ## Returns
  # - A list with a map containing commitment data and hash.
  # - An empty list in case of an error (DA server didn't respond, URL is not defined, or transaction input is incorrect).
  @spec alt_da_commitment_to_input(binary(), String.t(), String.t()) :: [
          %{
            :bytes => binary(),
            :alt_da_commitment => String.t()
          }
        ]
  defp alt_da_commitment_to_input("0x" <> transaction_input, transaction_hash, da_server_url) do
    transaction_input
    |> Base.decode16!(case: :mixed)
    |> alt_da_commitment_to_input(transaction_hash, da_server_url)
  end

  defp alt_da_commitment_to_input(transaction_input, _transaction_hash, da_server_url)
       when byte_size(transaction_input) == 2 + 32 and da_server_url != "" do
    commitment_for_url = binary_part(transaction_input, 1, 1 + 32)
    commitment_for_url_string = "0x" <> Base.encode16(commitment_for_url, case: :lower)

    url = da_server_url <> "/" <> commitment_for_url_string

    with {:ok, data} <- Helper.http_get_request(url, :raw),
         true <- byte_size(data) > 0 do
      [
        %{
          bytes: data,
          alt_da_commitment: "0x" <> Base.encode16(transaction_input, case: :lower)
        }
      ]
    else
      false ->
        Logger.error("DA server response is empty for the request #{url}")

        []

      _ ->
        Logger.error("Cannot read a response from DA server for the request #{url}")
        []
    end
  end

  defp alt_da_commitment_to_input(_transaction_input, transaction_hash, da_server_url) when da_server_url != "" do
    Logger.error("L1 transaction with Alt-DA commitment has incorrect input length. Tx hash: #{transaction_hash}")
    []
  end

  defp alt_da_commitment_to_input(_transaction_input, _transaction_hash, "") do
    Logger.error(
      "Cannot read data from the DA server as its URL is not defined. Please, check INDEXER_OPTIMISM_L1_BATCH_ALT_DA_SERVER_URL env variable."
    )

    []
  end

  defp get_transaction_batches_inner(
         transactions_filtered,
         blocks_params,
         span_batch_params,
         incomplete_channels,
         json_rpc_named_arguments_l2,
         {eip4844_blobs_api_url, eip4844_blobs_api_fallback_url, celestia_blobs_api_url, eigenda_blobs_api_url,
          alt_da_server_url, chain_id_l1}
       ) do
    transactions_filtered
    |> Enum.reduce({:ok, incomplete_channels, [], [], []}, fn transaction,
                                                              {_, incomplete_channels_acc, batches_acc, sequences_acc,
                                                               blobs_acc} ->
      inputs =
        cond do
          transaction.type == 3 ->
            # this is EIP-4844 transaction, so we get the inputs from EIP-4844 blobs
            block_timestamp = get_block_timestamp_by_number(transaction.block_number, blocks_params)

            transaction.hash
            |> eip4844_blobs_to_inputs(
              transaction.block_number,
              transaction.blob_versioned_hashes,
              block_timestamp,
              eip4844_blobs_api_url,
              eip4844_blobs_api_fallback_url,
              chain_id_l1
            )
            |> unwrap_mantle_blob_inputs(transaction.blob_versioned_hashes, transaction.block_number)

          commitment_alt_da_signature(transaction.input) == 0x01010C ->
            # this is Celestia DA transaction, so we get the data from Celestia blob
            celestia_blob_to_input(transaction.input, 3, transaction.hash, celestia_blobs_api_url)

          commitment_alt_da_signature(transaction.input) == 0x010100 ->
            # this is Eigen DA transaction, so we get the data from EigenDA blob
            eigenda_blob_to_input(transaction.input, 3, transaction.hash, eigenda_blobs_api_url)

          commitment_alt_da_signature(transaction.input) == 0x0100 ->
            # this is Alt-DA transaction with a keccak commitment, so we get the data from a DA server
            alt_da_commitment_to_input(transaction.input, transaction.hash, alt_da_server_url)

          first_byte(transaction.input) == 0xCE ->
            # backward compatibility with OP Celestia Raspberry
            celestia_blob_to_input(transaction.input, 1, transaction.hash, celestia_blobs_api_url)

          true ->
            # this is calldata transaction, so the data is in the transaction input
            [%{bytes: transaction.input}]
        end

      Enum.reduce(
        inputs,
        {:ok, incomplete_channels_acc, batches_acc, sequences_acc, blobs_acc},
        fn input, {_, new_incomplete_channels_acc, new_batches_acc, new_sequences_acc, new_blobs_acc} ->
          handle_input(
            input,
            transaction,
            blocks_params,
            new_incomplete_channels_acc,
            {new_batches_acc, new_sequences_acc, new_blobs_acc},
            span_batch_params,
            json_rpc_named_arguments_l2
          )
        end
      )
    end)
  end

  defp handle_input(
         input,
         transaction,
         blocks_params,
         incomplete_channels_acc,
         {batches_acc, sequences_acc, blobs_acc},
         span_batch_params,
         json_rpc_named_arguments_l2
       ) do
    frame = input_to_frame(input.bytes)

    if frame == :invalid_frame do
      Logger.warning("The frame in transaction #{transaction.hash} is invalid.")
      raise "Invalid frame"
    end

    block_timestamp = get_block_timestamp_by_number(transaction.block_number, blocks_params)

    channel = Map.get(incomplete_channels_acc, frame.channel_id, %{frames: %{}})

    channel_frames =
      Map.put(channel.frames, frame.number, %{
        data: frame.data,
        is_last: frame.is_last,
        block_number: transaction.block_number,
        block_timestamp: block_timestamp,
        transaction_hash: transaction.hash,
        eip4844_blob_hash: Map.get(input, :eip4844_blob_hash),
        eip4844_blob_hashes: Map.get(input, :eip4844_blob_hashes),
        celestia_blob_metadata: Map.get(input, :celestia_blob_metadata),
        eigenda_cert: Map.get(input, :eigenda_cert),
        alt_da_commitment: Map.get(input, :alt_da_commitment)
      })

    l1_timestamp =
      if frame.is_last do
        block_timestamp
      else
        Map.get(channel, :l1_timestamp)
      end

    channel_updated =
      channel
      |> Map.put_new(:id, frame.channel_id)
      |> Map.put(:frames, channel_frames)
      |> Map.put(:timestamp, DateTime.utc_now())
      |> Map.put(:l1_timestamp, l1_timestamp)

    if channel_complete?(channel_updated) do
      handle_channel(
        channel_updated,
        incomplete_channels_acc,
        batches_acc,
        sequences_acc,
        blobs_acc,
        span_batch_params,
        json_rpc_named_arguments_l2
      )
    else
      {:ok, Map.put(incomplete_channels_acc, frame.channel_id, channel_updated), batches_acc, sequences_acc, blobs_acc}
    end
  rescue
    e ->
      Logger.warning("Exception thrown: #{inspect(e)}")
      {:ok, incomplete_channels_acc, batches_acc, sequences_acc, blobs_acc}
  end

  defp handle_channel(
         channel,
         incomplete_channels_acc,
         batches_acc,
         sequences_acc,
         blobs_acc,
         span_batch_params,
         json_rpc_named_arguments_l2
       ) do
    frame_sequence_last = List.first(sequences_acc)
    frame_sequence_id = next_frame_sequence_id(frame_sequence_last)

    {bytes, l1_transaction_hashes, new_blobs_acc} =
      0..(Enum.count(channel.frames) - 1)
      |> Enum.reduce({<<>>, [], blobs_acc}, fn frame_number, {bytes_acc, transaction_hashes_acc, new_blobs_acc} ->
        frame = Map.get(channel.frames, frame_number)

        next_blob_id = next_blob_id(List.last(new_blobs_acc))

        new_blobs_acc =
          cond do
            !is_nil(Map.get(frame, :eip4844_blob_hash)) ->
              # frame data unwrapped from the joined blobs of a Mantle transaction keeps all of their hashes
              blob_hashes = Map.get(frame, :eip4844_blob_hashes) || [frame.eip4844_blob_hash]

              new_blobs_acc ++
                (blob_hashes
                 |> Enum.with_index(next_blob_id)
                 |> Enum.map(fn {blob_hash, id} ->
                   %{
                     id: id,
                     key: Base.decode16!(String.trim_leading(blob_hash, "0x"), case: :mixed),
                     type: :eip4844,
                     metadata: %{hash: blob_hash},
                     l1_transaction_hash: frame.transaction_hash,
                     l1_timestamp: frame.block_timestamp,
                     frame_sequence_id: frame_sequence_id
                   }
                 end))

            !is_nil(Map.get(frame, :celestia_blob_metadata)) ->
              height = :binary.encode_unsigned(frame.celestia_blob_metadata.height)

              commitment =
                Base.decode16!(String.trim_leading(frame.celestia_blob_metadata.commitment, "0x"),
                  case: :mixed
                )

              # credo:disable-for-next-line /Credo.Check.Refactor.AppendSingleItem/
              new_blobs_acc ++
                [
                  %{
                    id: next_blob_id,
                    key: :crypto.hash(:sha256, height <> commitment),
                    type: :celestia,
                    metadata: frame.celestia_blob_metadata,
                    l1_transaction_hash: frame.transaction_hash,
                    l1_timestamp: frame.block_timestamp,
                    frame_sequence_id: frame_sequence_id
                  }
                ]

            !is_nil(Map.get(frame, :eigenda_cert)) ->
              # credo:disable-for-next-line /Credo.Check.Refactor.AppendSingleItem/
              new_blobs_acc ++
                [
                  %{
                    id: next_blob_id,
                    key: :crypto.hash(:sha256, frame.eigenda_cert),
                    type: :eigenda,
                    metadata: %{cert: "0x" <> Base.encode16(frame.eigenda_cert, case: :lower)},
                    l1_transaction_hash: frame.transaction_hash,
                    l1_timestamp: frame.block_timestamp,
                    frame_sequence_id: frame_sequence_id
                  }
                ]

            !is_nil(Map.get(frame, :alt_da_commitment)) ->
              # credo:disable-for-next-line /Credo.Check.Refactor.AppendSingleItem/
              new_blobs_acc ++
                [
                  %{
                    id: next_blob_id,
                    key: Base.decode16!(String.trim_leading(frame.alt_da_commitment, "0x"), case: :mixed),
                    type: :alt_da,
                    metadata: %{commitment: frame.alt_da_commitment},
                    l1_transaction_hash: frame.transaction_hash,
                    l1_timestamp: frame.block_timestamp,
                    frame_sequence_id: frame_sequence_id
                  }
                ]

            true ->
              new_blobs_acc
          end

        {bytes_acc <> frame.data, [frame.transaction_hash | transaction_hashes_acc], new_blobs_acc}
      end)

    batches_parsed =
      parse_frame_sequence(
        bytes,
        frame_sequence_id,
        channel.l1_timestamp,
        span_batch_params,
        json_rpc_named_arguments_l2
      )

    if batches_parsed == :error do
      Logger.error("Cannot parse frame sequence from these L1 transaction(s): #{inspect(l1_transaction_hashes)}")
    end

    sequence = %{
      id: frame_sequence_id,
      l1_transaction_hashes: Enum.uniq(Enum.reverse(l1_transaction_hashes)),
      l1_timestamp: channel.l1_timestamp
    }

    new_incomplete_channels_acc =
      incomplete_channels_acc
      |> Map.delete(channel.id)
      |> remove_expired_channels()

    if batches_parsed == :error or Enum.empty?(batches_parsed) do
      {:ok, new_incomplete_channels_acc, batches_acc, sequences_acc, blobs_acc}
    else
      {:ok, new_incomplete_channels_acc, batches_acc ++ batches_parsed, [sequence | sequences_acc], new_blobs_acc}
    end
  end

  defp handle_l1_reorg(reorg_block, incomplete_channels) do
    incomplete_channels
    |> Enum.reduce(incomplete_channels, fn {channel_id, %{frames: frames} = channel}, acc ->
      updated_frames =
        frames
        |> Enum.filter(fn {_frame_number, %{block_number: block_number}} ->
          block_number < reorg_block
        end)
        |> Enum.into(%{})

      if Enum.empty?(updated_frames) do
        Map.delete(acc, channel_id)
      else
        Map.put(acc, channel_id, Map.put(channel, :frames, updated_frames))
      end
    end)
  end

  @doc """
    Removes rows from op_transaction_batches and op_frame_sequences tables written beginning from the L2 reorg block.
  """
  @spec handle_l2_reorg(non_neg_integer()) :: any()
  def handle_l2_reorg(reorg_block) do
    frame_sequence_ids =
      Repo.all(
        from(
          tb in OptimismTransactionBatch,
          select: tb.frame_sequence_id,
          where: tb.l2_block_number >= ^reorg_block
        ),
        timeout: :infinity
      )

    {deleted_count, _} =
      Repo.delete_all(from(tb in OptimismTransactionBatch, where: tb.l2_block_number >= ^reorg_block))

    Repo.delete_all(from(fs in FrameSequence, where: fs.id in ^frame_sequence_ids))

    if deleted_count > 0 do
      Logger.warning(
        "As L2 reorg was detected, all rows with l2_block_number >= #{reorg_block} were removed from the op_transaction_batches table. Number of removed rows: #{deleted_count}."
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

  defp channel_complete?(channel) do
    last_frame_number =
      channel.frames
      |> Map.keys()
      |> Enum.max()

    Map.get(channel.frames, last_frame_number).is_last and
      last_frame_number == Enum.count(channel.frames) - 1
  end

  defp remove_expired_channels(channels_map) do
    now = DateTime.utc_now()

    Enum.reduce(channels_map, channels_map, fn {channel_id, %{timestamp: timestamp}}, channels_acc ->
      if DateTime.diff(now, timestamp) >= 86400 do
        Map.delete(channels_acc, channel_id)
      else
        channels_acc
      end
    end)
  end

  defp input_to_frame("0x" <> input) do
    input
    |> Base.decode16!(case: :mixed)
    |> input_to_frame()
  end

  defp input_to_frame(input_binary) do
    # the structure of the input is as follows:
    #
    # input = derivation_version ++ channel_id ++ frame_number ++ frame_data_length ++ frame_data ++ is_last
    #
    # derivation_version = uint8
    # channel_id         = bytes16
    # frame_number       = uint16
    # frame_data_length  = uint32
    # frame_data         = bytes
    # is_last            = bool (uint8)

    derivation_version_length = 1
    channel_id_length = 16
    frame_number_size = 2
    frame_data_length_size = 4
    is_last_size = 1

    # the first byte must be zero
    derivation_version = first_byte(input_binary)

    if derivation_version != 0x00 do
      Logger.warning("Derivation version #{derivation_version} is not supported. The frame will be ignored.")

      raise "Unsupported derivation version"
    end

    # channel id has 16 bytes
    channel_id = binary_part(input_binary, derivation_version_length, channel_id_length)

    # frame number consists of 2 bytes
    frame_number_offset = derivation_version_length + channel_id_length

    frame_number = :binary.decode_unsigned(binary_part(input_binary, frame_number_offset, frame_number_size))

    # frame data length consists of 4 bytes
    frame_data_length_offset = frame_number_offset + frame_number_size

    frame_data_length =
      :binary.decode_unsigned(binary_part(input_binary, frame_data_length_offset, frame_data_length_size))

    input_length_must_be =
      derivation_version_length + channel_id_length + frame_number_size + frame_data_length_size +
        frame_data_length +
        is_last_size

    input_length_current = byte_size(input_binary)

    if input_length_current == input_length_must_be do
      # frame data is a byte array of frame_data_length size
      frame_data_offset = frame_data_length_offset + frame_data_length_size
      frame_data = binary_part(input_binary, frame_data_offset, frame_data_length)

      # is_last is 1-byte item
      is_last_offset = frame_data_offset + frame_data_length

      is_last = :binary.decode_unsigned(binary_part(input_binary, is_last_offset, is_last_size)) > 0

      %{number: frame_number, data: frame_data, is_last: is_last, channel_id: channel_id}
    else
      # workaround to remove a leading extra byte
      # for example, the case for Base Goerli batch L1 transaction: https://goerli.etherscan.io/tx/0xa43fa9da683a6157a114e3175a625b5aed85d8c573aae226768c58a924a17be0
      input_to_frame("0x" <> Base.encode16(binary_part(input_binary, 1, input_length_current - 1)))
    end
  rescue
    _ -> :invalid_frame
  end

  defp next_blob_id(last_known_blob) when is_nil(last_known_blob) do
    last_known_id =
      Repo.one(
        from(
          fsb in FrameSequenceBlob,
          select: fsb.id,
          order_by: [desc: fsb.id],
          limit: 1
        )
      )

    if is_nil(last_known_id) do
      1
    else
      last_known_id + 1
    end
  end

  defp next_blob_id(last_known_blob) do
    last_known_blob.id + 1
  end

  defp next_frame_sequence_id(last_known_sequence) when is_nil(last_known_sequence) do
    last_known_id =
      Repo.one(
        from(
          fs in FrameSequence,
          select: fs.id,
          order_by: [desc: fs.id],
          limit: 1
        )
      )

    if is_nil(last_known_id) do
      1
    else
      last_known_id + 1
    end
  end

  defp next_frame_sequence_id(last_known_sequence) do
    last_known_sequence.id + 1
  end

  @doc false
  # Parses the batches of a complete channel into a list of `%{l2_block_number, frame_sequence_id, l1_timestamp}`,
  # one item per L2 block, or `:error` when the channel does not parse.
  #
  # ## Parameters
  # - `bytes`: The compressed channel data.
  # - `id`: The id of the frame sequence the channel forms.
  # - `l1_timestamp`: The timestamp of the L1 block of the channel's last frame.
  # - `span_batch_params`: `{genesis_block_l2, block_duration, genesis_time_offset}`, to map span batches to L2 blocks.
  # - `json_rpc_named_arguments_l2`: Configuration parameters for the JSON RPC connection to the L2 node.
  @spec parse_frame_sequence(
          binary(),
          non_neg_integer(),
          DateTime.t(),
          {non_neg_integer(), pos_integer(), integer()},
          EthereumJSONRPC.json_rpc_named_arguments()
        ) :: [map()] | :error
  def parse_frame_sequence(
        bytes,
        id,
        l1_timestamp,
        span_batch_params,
        json_rpc_named_arguments_l2
      ) do
    uncompressed_bytes =
      if first_byte(bytes) == @compressor_brotli do
        bytes
        |> binary_part(1, byte_size(bytes) - 1)
        |> ExBrotli.decompress!()
      else
        zlib_decompress(bytes)
      end

    batches =
      Enum.reduce_while(Stream.iterate(0, &(&1 + 1)), {uncompressed_bytes, []}, fn _i, {remainder, batch_acc} ->
        try do
          {decoded, new_remainder} = ExRLP.decode(remainder, stream: true)

          <<version::size(8), content::binary>> = decoded

          new_batch_acc =
            cond do
              version == 0 ->
                handle_v0_batch(content, id, l1_timestamp, batch_acc)

              version <= 2 ->
                # parsing the span batch
                handle_v1_batch(content, id, l1_timestamp, span_batch_params, batch_acc)

              true ->
                Logger.error("Unsupported batch version ##{version}")
                :error
            end

          if byte_size(new_remainder) > 0 and new_batch_acc != :error do
            {:cont, {new_remainder, new_batch_acc}}
          else
            {:halt, new_batch_acc}
          end
        rescue
          _ -> {:halt, :error}
        end
      end)

    if batches == :error do
      :error
    else
      batches = Enum.reverse(batches)

      numbers_by_hashes =
        batches
        |> Enum.filter(&Map.has_key?(&1, :parent_hash))
        |> Enum.map(& &1.parent_hash)
        |> resolved_parent_numbers(json_rpc_named_arguments_l2)

      verified_spans =
        batches
        |> Enum.filter(&Map.has_key?(&1, :parent_check))
        |> verified_spans(json_rpc_named_arguments_l2)

      Enum.flat_map(batches, &to_l2_blocks(&1, numbers_by_hashes, verified_spans))
    end
  end

  defp handle_v0_batch(content, frame_sequence_id, l1_timestamp, batch_acc) do
    content_decoded = ExRLP.decode(content)

    batch = %{
      parent_hash: Enum.at(content_decoded, 0),
      frame_sequence_id: frame_sequence_id,
      l1_timestamp: l1_timestamp
    }

    [batch | batch_acc]
  end

  # A span batch counts its first block's timestamp from the rollup's genesis time (`genesis.l2_time` in the rollup
  # config), which can precede the timestamp of the genesis block by `genesis_time_offset` seconds. Its `parent_check`
  # is the beginning of the hash of the block before its first block, checked in `to_l2_blocks/3`.
  defp handle_v1_batch(
         content,
         frame_sequence_id,
         l1_timestamp,
         {genesis_block_l2, block_duration, genesis_time_offset},
         batch_acc
       ) do
    {rel_timestamp, content_remainder} = LEB128.decode(content)

    # skip l1_origin_num
    {_l1_origin_num, checks_and_payload} = LEB128.decode(content_remainder)

    # read `parent_check` (20 bytes), skip `l1_origin_check` (20 bytes), and read the block count
    <<parent_check::binary-size(20), _l1_origin_check::binary-size(20), payload::binary>> = checks_and_payload
    {block_count, _} = LEB128.decode(payload)

    seconds_after_genesis_block = rel_timestamp - genesis_time_offset

    cond do
      seconds_after_genesis_block < 0 or rem(seconds_after_genesis_block, block_duration) != 0 ->
        Logger.error(
          "The span batch with rel_timestamp #{rel_timestamp} does not start at an L2 block. Check INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER and INDEXER_OPTIMISM_L2_BATCH_GENESIS_L2_TIME against the rollup config. We ignore the span batch."
        )

        batch_acc

      block_count <= 0 ->
        Logger.error("Empty span batch found. We ignore it.")
        batch_acc

      true ->
        # the first and last L2 blocks in the span
        span_start = div(seconds_after_genesis_block, block_duration) + genesis_block_l2

        [
          %{
            span_start: span_start,
            span_end: span_start + block_count - 1,
            parent_check: parent_check,
            frame_sequence_id: frame_sequence_id,
            l1_timestamp: l1_timestamp
          }
          | batch_acc
        ]
    end
  end

  # The L2 blocks of a batch: the block after the parent of a singular batch, or the blocks of a verified span batch
  # (see `verified_spans/2`).
  defp to_l2_blocks(%{parent_hash: parent_hash} = batch, numbers_by_hashes, _verified_spans) do
    case Map.get(numbers_by_hashes, parent_hash) do
      nil ->
        Logger.error(
          "The singular batch after the L2 block 0x#{Base.encode16(parent_hash, case: :lower)} is not mapped, as the L2 node does not give that block. Unless the node lags behind, the batch is invalid. We ignore the batch."
        )

        []

      number ->
        [
          batch
          |> Map.put(:l2_block_number, number + 1)
          |> Map.delete(:parent_hash)
        ]
    end
  end

  defp to_l2_blocks(
         %{span_start: span_start, span_end: span_end, parent_check: parent_check} = batch,
         _numbers_by_hashes,
         verified_spans
       ) do
    if MapSet.member?(verified_spans, {span_start, parent_check}) do
      Enum.map(
        span_start..span_end,
        &%{l2_block_number: &1, frame_sequence_id: batch.frame_sequence_id, l1_timestamp: batch.l1_timestamp}
      )
    else
      []
    end
  end

  # Returns a `hash -> number` map of the parents of singular batches. The L2 node can lag behind the batches, so a
  # parent it does not return is asked for again, as the block before a span batch is (see `verified_spans/2`), and a
  # singular batch whose parent does not come is left out (see `to_l2_blocks/3`).
  defp resolved_parent_numbers([], _json_rpc_named_arguments_l2), do: %{}

  defp resolved_parent_numbers(parent_hashes, json_rpc_named_arguments_l2) do
    attempts = parent_check_setting(:attempts)
    deadline = System.monotonic_time(:millisecond) + attempts * parent_check_setting(:interval)

    resolve_parents(Enum.uniq(parent_hashes), json_rpc_named_arguments_l2, {attempts, deadline}, %{})
  end

  defp resolve_parents(hashes, json_rpc_named_arguments_l2, {attempts_left, deadline}, resolved) do
    case get_block_numbers_by_hashes(hashes, json_rpc_named_arguments_l2) do
      :unavailable ->
        new_deadline = wait_for_l2_node("the parents of singular batches", attempts_left)
        resolve_parents(hashes, json_rpc_named_arguments_l2, {attempts_left, new_deadline}, resolved)

      numbers_by_hashes ->
        resolved = Map.merge(resolved, numbers_by_hashes)
        pending = Enum.reject(hashes, &Map.has_key?(numbers_by_hashes, &1))

        if pending == [] or attempts_left <= 1 or System.monotonic_time(:millisecond) >= deadline do
          resolved
        else
          Logger.warning(
            "Waiting for the L2 node to give the parent(s) #{inspect(Enum.map(pending, &("0x" <> Base.encode16(&1, case: :lower))))} of singular batch(es)..."
          )

          :timer.sleep(parent_check_setting(:interval))
          resolve_parents(pending, json_rpc_named_arguments_l2, {attempts_left - 1, deadline}, resolved)
        end
    end
  end

  # Waits for an L2 node that does not answer, as the other L2 requests do, without spending the checks of the
  # parents, which are for a node that answers without them. Returns the deadline of the checks left, which starts
  # again once the node answers.
  defp wait_for_l2_node(subject, attempts_left) do
    Logger.warning("The L2 node does not answer the requests for #{subject}. Retrying...")
    interval = parent_check_setting(:interval)
    :timer.sleep(interval)
    System.monotonic_time(:millisecond) + attempts_left * interval
  end

  # Returns `{span_start, parent_check}` of the span batches whose `parent_check` matches the hash of the L2 block before
  # them.
  #
  # A span batch that does not match a safe block was mapped to the wrong blocks, as the genesis settings do not
  # match the rollup config, or is invalid: it is left out. The L2 node can lag behind the batches, though, or still
  # have the block before a span batch on an unsafe chain that derivation replaces, so a span batch whose block before
  # is missing or not safe yet is checked again, `parent_check_interval` milliseconds apart, up to
  # `parent_check_attempts` times and within that many intervals in all, before it is left out.
  defp verified_spans(spans, json_rpc_named_arguments_l2) do
    {before_first_block, spans} = Enum.split_with(spans, &(&1.span_start < 1))
    Enum.each(before_first_block, &log_span_left_out(&1, "starts before the first L2 block"))

    attempts = parent_check_setting(:attempts)
    deadline = System.monotonic_time(:millisecond) + attempts * parent_check_setting(:interval)

    verify_spans(spans, json_rpc_named_arguments_l2, {attempts, deadline}, MapSet.new())
  end

  defp verify_spans([], _json_rpc_named_arguments_l2, _limits, verified), do: verified

  defp verify_spans(spans, json_rpc_named_arguments_l2, {attempts_left, deadline}, verified) do
    with %{} = hashes_by_numbers <-
           spans |> Enum.map(&(&1.span_start - 1)) |> get_block_hashes_by_numbers(json_rpc_named_arguments_l2),
         {matching, mismatching_safe, pending} <-
           classify_spans(spans, hashes_by_numbers, json_rpc_named_arguments_l2) do
      Enum.each(mismatching_safe, &log_span_left_out(&1, "does not follow the safe L2 block #{&1.span_start - 1}"))

      verified = Enum.reduce(matching, verified, &MapSet.put(&2, {&1.span_start, &1.parent_check}))

      cond do
        pending == [] ->
          verified

        attempts_left <= 1 or System.monotonic_time(:millisecond) >= deadline ->
          Enum.each(
            pending,
            &log_span_left_out(
              &1,
              "is not checked, as the L2 node does not give the safe L2 block #{&1.span_start - 1}"
            )
          )

          verified

        true ->
          Logger.warning(
            "Waiting for the L2 node to give the safe L2 block(s) #{inspect(Enum.map(pending, &(&1.span_start - 1)))}, which the span batch(es) after them must follow..."
          )

          :timer.sleep(parent_check_setting(:interval))
          verify_spans(pending, json_rpc_named_arguments_l2, {attempts_left - 1, deadline}, verified)
      end
    else
      :unavailable ->
        new_deadline = wait_for_l2_node("the blocks before span batches", attempts_left)
        verify_spans(spans, json_rpc_named_arguments_l2, {attempts_left, new_deadline}, verified)
    end
  end

  # Splits span batches into those matching their block before, those not matching it while it is safe, and the
  # others (their block before is missing or not safe), or returns `:unavailable` when the L2 node does not answer.
  # The safe block is read only when some span batch does not match, and then its non-matching blocks before are read
  # again: derivation can replace one and make it safe after it was read.
  defp classify_spans(spans, hashes_by_numbers, json_rpc_named_arguments_l2) do
    {matching, other} = Enum.split_with(spans, &parent_matches?(&1, hashes_by_numbers))
    {mismatching, missing} = Enum.split_with(other, &Map.has_key?(hashes_by_numbers, &1.span_start - 1))

    if mismatching == [] do
      {matching, [], missing}
    else
      with {:ok, safe_block_number} <- Helper.get_block_number_by_tag("safe", json_rpc_named_arguments_l2, 1),
           %{} = hashes_by_numbers_again <-
             mismatching |> Enum.map(&(&1.span_start - 1)) |> get_block_hashes_by_numbers(json_rpc_named_arguments_l2) do
        {matching_again, mismatching_again} =
          Enum.split_with(mismatching, &parent_matches?(&1, hashes_by_numbers_again))

        {mismatching_safe, mismatching_unsafe} =
          Enum.split_with(
            mismatching_again,
            &(&1.span_start - 1 <= safe_block_number and Map.has_key?(hashes_by_numbers_again, &1.span_start - 1))
          )

        {matching ++ matching_again, mismatching_safe, mismatching_unsafe ++ missing}
      else
        # the L2 node does not answer, about the safe block or the blocks before
        _ -> :unavailable
      end
    end
  end

  defp parent_matches?(%{span_start: span_start, parent_check: parent_check}, hashes_by_numbers) do
    match?(<<^parent_check::binary-size(20), _::binary>>, Map.get(hashes_by_numbers, span_start - 1))
  end

  defp log_span_left_out(%{span_start: span_start, span_end: span_end}, reason) do
    Logger.error(
      "The span batch mapped to L2 blocks #{span_start}..#{span_end} #{reason}. Check INDEXER_OPTIMISM_L2_BATCH_GENESIS_BLOCK_NUMBER and INDEXER_OPTIMISM_L2_BATCH_GENESIS_L2_TIME against the rollup config, unless the batch is invalid. We ignore the span batch."
    )
  end

  defp parent_check_setting(:attempts),
    do: Application.get_all_env(:indexer)[__MODULE__][:parent_check_attempts] || @parent_check_attempts

  defp parent_check_setting(:interval),
    do: Application.get_all_env(:indexer)[__MODULE__][:parent_check_interval] || @parent_check_interval

  # Returns a `number -> hash` map of the given L2 blocks that the L2 node returns (the indexed blocks can lag behind
  # the batches, or still hold a block the node replaced), or `:unavailable` when the node does not answer.
  defp get_block_hashes_by_numbers(numbers, json_rpc_named_arguments_l2) do
    numbers
    |> Enum.uniq()
    |> Enum.chunk_every(@l2_blocks_request_size)
    |> Enum.reduce_while(%{}, fn chunk, acc ->
      case request_block_hashes(chunk, json_rpc_named_arguments_l2) do
        :unavailable -> {:halt, :unavailable}
        hashes -> {:cont, Enum.into(hashes, acc)}
      end
    end)
  end

  # Returns `{number, hash}` of each of the given L2 blocks that the node returns, or `:unavailable` when the node does
  # not answer.
  defp request_block_hashes(numbers, json_rpc_named_arguments_l2) do
    requests =
      numbers
      |> Enum.with_index()
      |> Enum.map(fn {number, id} -> ByNumber.request(%{id: id, number: number}, false) end)

    error_message = &"Cannot fetch L2 blocks #{inspect(numbers)}. Error: #{inspect(&1)}"

    # one attempt: `verified_spans/2` checks a span batch again in a while
    case Helper.repeated_call(&json_rpc/2, [requests, json_rpc_named_arguments_l2], error_message, 1) do
      {:ok, responses} ->
        Enum.flat_map(responses, fn
          %{result: %{"number" => number, "hash" => "0x" <> hash}} ->
            [{quantity_to_integer(number), Base.decode16!(hash, case: :mixed)}]

          _ ->
            []
        end)

      {:error, _} ->
        :unavailable
    end
  end

  # Returns the seconds from the rollup's genesis time (`genesis.l2_time` in the rollup config, which span batches
  # count their timestamps from) to the timestamp of the genesis block: none unless the genesis time is given.
  @spec genesis_time_offset(
          non_neg_integer(),
          non_neg_integer() | nil,
          EthereumJSONRPC.json_rpc_named_arguments()
        ) :: {:ok, integer()} | {:error, any()}
  defp genesis_time_offset(_genesis_block_l2, nil, _json_rpc_named_arguments_l2), do: {:ok, 0}

  defp genesis_time_offset(genesis_block_l2, genesis_l2_time, json_rpc_named_arguments_l2) do
    with {:ok, genesis_block_timestamp} <-
           Helper.get_block_timestamp_by_number_or_tag(
             genesis_block_l2,
             json_rpc_named_arguments_l2,
             Helper.infinite_retries_number()
           ) do
      {:ok, genesis_block_timestamp - genesis_l2_time}
    end
  end

  defp remove_duplicates(batches, sequences, blobs) do
    unique_batches =
      batches
      |> Enum.sort(fn b1, b2 ->
        b1.l2_block_number < b2.l2_block_number or
          (b1.l2_block_number == b2.l2_block_number and b1.l1_timestamp < b2.l1_timestamp)
      end)
      |> Enum.reduce(%{}, fn b, acc ->
        Map.put(acc, b.l2_block_number, Map.delete(b, :l1_timestamp))
      end)
      |> Map.values()

    unique_sequences =
      sequences
      |> Enum.reverse()
      |> Enum.filter(fn seq ->
        Enum.any?(unique_batches, fn batch -> batch.frame_sequence_id == seq.id end)
      end)

    unique_blobs =
      blobs
      |> Enum.reduce(%{}, fn b, acc ->
        prev_id = Map.get(acc, b.key, %{id: 0}).id

        if prev_id < b.id do
          Map.put(acc, b.key, b)
        else
          acc
        end
      end)
      |> Map.values()
      |> Enum.filter(fn b ->
        Enum.any?(unique_sequences, fn sec -> sec.id == b.frame_sequence_id end)
      end)

    {unique_batches, unique_sequences, unique_blobs}
  end

  defp remove_prev_frame_sequences(inserted) do
    ids =
      inserted
      |> Map.get(:insert_transaction_batches, [])
      |> Enum.map(fn tb -> tb.frame_sequence_id_prev end)
      |> Enum.uniq()
      |> Enum.filter(fn id -> id > 0 end)

    try do
      Repo.delete_all(from(fs in FrameSequence, where: fs.id in ^ids))
    rescue
      # we need to ignore `foreign_key_violation` exception when deleting the rows
      # because there can be a case when the chain partially replaces the frame sequence
      # (e.g. Unichain Private Testnet), and so some rows in `op_transaction_batches` table
      # can still reference to the `op_frame_sequences` table
      _ -> nil
    end

    ids
  end

  defp set_frame_sequences_view_ready(sequences) do
    sequence_ids = Enum.map(sequences, fn s -> s.id end)

    Repo.update_all(
      from(fs in FrameSequence, where: fs.id in ^sequence_ids),
      set: [view_ready: true]
    )
  end

  # Keeps transactions sent to the inbox by the batcher authorized at their L1 block.
  defp transactions_filter(transactions_params, batcher_timeline, batch_inbox) do
    transactions_params
    |> Enum.filter(fn t ->
      from_address_hash = Map.get(t, :from_address_hash)
      to_address_hash = Map.get(t, :to_address_hash)

      if is_nil(from_address_hash) or is_nil(to_address_hash) do
        false
      else
        String.downcase(to_address_hash) == batch_inbox and
          String.downcase(from_address_hash) == BatcherTimeline.address_at(batcher_timeline, t.block_number)
      end
    end)
    |> Enum.sort(fn t1, t2 ->
      {t1.block_number, t1.index} < {t2.block_number, t2.index}
    end)
  end

  @doc false
  @spec validate_eip4844_blob_hashes([map()]) :: :ok | {:error, String.t()}
  def validate_eip4844_blob_hashes(transactions) when is_list(transactions) do
    transactions
    |> Enum.find(fn transaction ->
      Map.get(transaction, :type) == 3 and
        transaction
        |> Map.get(:blob_versioned_hashes)
        |> missing_blob_versioned_hashes?()
    end)
    |> case do
      nil ->
        :ok

      transaction ->
        {:error,
         "EIP-4844 transaction #{Map.get(transaction, :hash)} in L1 block #{Map.get(transaction, :block_number)} " <>
           "has no blobVersionedHashes. Retrying block fetch to avoid silently dropping blob batches."}
    end
  end

  defp missing_blob_versioned_hashes?(blob_versioned_hashes) do
    is_nil(blob_versioned_hashes) or blob_versioned_hashes == []
  end

  # Reads some public getters of SystemConfig contract and returns retrieved values.
  # Gets the number of a start block (from which this fetcher should start) and the inbox address.
  # The batcher (batch submitter) can change over time, so it is tracked by `BatcherTimeline`.
  #
  # If SystemConfig has obsolete implementation, the values are fallen back from the corresponding
  # env variables (INDEXER_OPTIMISM_L1_START_BLOCK, INDEXER_OPTIMISM_L1_BATCH_INBOX).
  #
  # ## Parameters
  # - `contract_address`: An address of SystemConfig contract.
  # - `json_rpc_named_arguments`: Configuration parameters for the JSON RPC connection.
  #
  # ## Returns
  # - A tuple: {start_block, inbox}.
  # - `nil` in case of error.
  @spec read_system_config(String.t(), EthereumJSONRPC.json_rpc_named_arguments()) ::
          {non_neg_integer(), String.t()} | nil
  defp read_system_config(contract_address, json_rpc_named_arguments) do
    requests = [
      # startBlock() public getter
      Contract.eth_call_request("0x48cd4cb1", contract_address, 0, nil, nil),
      # batchInbox() public getter
      Contract.eth_call_request("0xdac6e63a", contract_address, 1, nil, nil)
    ]

    error_message = &"Cannot call public getters of SystemConfig. Error: #{inspect(&1)}"

    env = Application.get_all_env(:indexer)[__MODULE__]
    fallback_start_block = Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism][:start_block_l1]

    {start_block, batch_inbox} =
      case Helper.repeated_call(
             &json_rpc/2,
             [requests, json_rpc_named_arguments],
             error_message,
             Helper.finite_retries_number()
           ) do
        {:ok, responses} ->
          results = Map.new(responses, &{&1.id, Map.get(&1, :result)})

          batch_inbox =
            case results[1] do
              "0x000000000000000000000000" <> batch_inbox -> "0x" <> batch_inbox
              _ -> env[:inbox]
            end

          {quantity_to_integer(results[0] || fallback_start_block), batch_inbox}

        _ ->
          {fallback_start_block, env[:inbox]}
      end

    if !is_nil(start_block) and Helper.address_correct?(batch_inbox) do
      {start_block, String.downcase(batch_inbox)}
    end
  end

  # Retrieves Alt-DA signature from L1 transaction input as described in
  # https://github.com/ethereum-optimism/specs/blob/main/specs/experimental/alt-da.md#example-commitments
  #
  # ## Parameters
  # - `transaction_input`: The contents of transaction `input` field.
  #
  # ## Returns
  # - An integer encoding the signature.
  # - `nil` if the input doesn't contain Alt-DA signature.
  @spec commitment_alt_da_signature(binary()) :: non_neg_integer() | nil
  defp commitment_alt_da_signature("0x" <> transaction_input) do
    transaction_input
    |> Base.decode16!(case: :mixed)
    |> commitment_alt_da_signature()
  end

  defp commitment_alt_da_signature(<<0, _rest::binary>>), do: 0x00
  defp commitment_alt_da_signature(<<1, 0, _rest::binary>>), do: 0x0100

  defp commitment_alt_da_signature(<<1, 1, da_layer_byte::size(8), _rest::binary>>),
    do: :binary.decode_unsigned(<<0x01, 0x01, da_layer_byte>>)

  defp commitment_alt_da_signature(_), do: nil

  defp first_byte("0x" <> transaction_input) do
    transaction_input
    |> Base.decode16!(case: :mixed)
    |> first_byte()
  end

  defp first_byte(<<first_byte::size(8), _rest::binary>>) do
    first_byte
  end

  defp first_byte(_transaction_input) do
    nil
  end

  defp zlib_decompress(bytes) do
    z = :zlib.open()
    :zlib.inflateInit(z)

    uncompressed_bytes =
      try do
        zlib_inflate(z, bytes)
      rescue
        _ -> <<>>
      end

    try do
      :zlib.inflateEnd(z)
    rescue
      _ -> nil
    end

    :zlib.close(z)

    uncompressed_bytes
  end

  defp zlib_inflate_handler(z, {:continue, [uncompressed_bytes]}, acc) do
    zlib_inflate(z, [], acc <> uncompressed_bytes)
  end

  defp zlib_inflate_handler(_z, {:finished, [uncompressed_bytes]}, acc) do
    acc <> uncompressed_bytes
  end

  defp zlib_inflate_handler(_z, {:finished, []}, acc) do
    acc
  end

  defp zlib_inflate(z, compressed_bytes, acc \\ <<>>) do
    result = :zlib.safeInflate(z, compressed_bytes)
    zlib_inflate_handler(z, result, acc)
  end
end
