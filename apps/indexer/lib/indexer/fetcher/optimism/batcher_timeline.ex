defmodule Indexer.Fetcher.Optimism.BatcherTimeline do
  @moduledoc """
  Tracks the batch submitter (batcher) authorized by the SystemConfig contract at each L1 block.

  The batcher is rotated with `SystemConfig.setBatcherHash`, which emits
  `ConfigUpdate(version = 0, updateType = BATCHER, data)`. Like op-node, an update applies to the
  whole L1 block containing it, the last valid update in log order wins within a block, and
  malformed updates are ignored.

  The batcher at the first block of the timeline (the seed) is read from SystemConfig: at that block,
  which needs historical state, or at the finalized block if the batcher was not changed since that
  block. On a fresh start the first block is the start block, where `INDEXER_OPTIMISM_L1_BATCH_SUBMITTER`
  is used only when neither can be read. SystemConfig's `initialize()` emits no event, so the seed
  cannot be derived from logs.

  After a restart only the history from the block the caller resumes from is read. If the batcher
  there is unknown, the history is read from the start block instead. The timeline extends back on
  demand when the caller processes older blocks again; that history must lead to the batcher known at
  the timeline's first block.

  The history up to the finalized block is read with ranged `eth_getLogs` requests. Each of them is
  sent in a batch with the header of the range's last block, so a node behind a load balancer that
  does not have the whole range is detected, and the result must agree with `batcherHash()` at the
  finalized block. Every later block is read by its hash (EIP-234), for exactly the blocks whose
  transactions are filtered, and the hashes are kept: blocks processed again must have the same
  hashes, new blocks must extend the last one, and a block becomes final only when it is the block
  finalized on L1. Otherwise `{:reorg, block}` asks the caller to process the unfinalized blocks
  again after `truncate/2`.
  """

  require Logger

  import EthereumJSONRPC, only: [integer_to_quantity: 1, json_rpc: 2, quantity_to_integer: 1, request: 1]

  alias Indexer.Helper

  @config_update_event "0x" <> Base.encode16(ExKeccak.hash_256("ConfigUpdate(uint256,uint8,bytes)"), case: :lower)
  # both indexed topics are zero: ConfigUpdate version 0 and UpdateType.BATCHER
  @zero_topic "0x" <> String.duplicate("0", 64)
  @batcher_update_topics [@config_update_event, @zero_topic, @zero_topic]
  # batcherHash() public getter
  @batcher_hash_selector "0xe81b2c6d"
  @zero_address "0x" <> String.duplicate("0", 40)
  # max number of requests in one JSON-RPC batch
  @rpc_batch_size 100

  @enforce_keys [:contract, :start_block, :first_block, :submitter, :range_size, :seed, :finalized, :through]
  defstruct [
    :contract,
    :start_block,
    :first_block,
    :submitter,
    :range_size,
    :seed,
    :finalized,
    :through,
    hashes: %{},
    updates: []
  ]

  @typedoc """
  - `contract`: SystemConfig address in lower case.
  - `start_block`: The first L1 block of the rollup history; nobody is authorized before it.
  - `first_block`: The first L1 block whose batcher is known: `start_block`, the block the caller
    resumed from, or an older block it processed again.
  - `submitter`: Value of `INDEXER_OPTIMISM_L1_BATCH_SUBMITTER`, the batcher at `start_block`.
  - `range_size`: Max number of L1 blocks in one ranged `eth_getLogs` request.
  - `seed`: The batcher at `first_block` before any update.
  - `finalized`: Updates at or below this L1 block are final.
  - `through`: Updates are known for every L1 block up to this one.
  - `hashes`: Hashes of the L1 blocks from `finalized` up to `through` whose updates were read.
  - `updates`: `{l1_block_number, batcher}` pairs sorted by the block number in descending order.
  """
  @type t :: %__MODULE__{
          contract: String.t(),
          start_block: non_neg_integer(),
          first_block: non_neg_integer(),
          submitter: String.t() | nil,
          range_size: pos_integer(),
          seed: String.t(),
          finalized: non_neg_integer(),
          through: non_neg_integer(),
          hashes: %{non_neg_integer() => String.t()},
          updates: [{non_neg_integer(), String.t()}]
        }

  @doc """
    Builds the timeline up to the finalized L1 block, from `start_block` or from the block the caller
    resumes from. Waits until `start_block` is finalized, since a reorg could replace the seed read at
    an unfinalized block.

    ## Parameters
    - `contract`: SystemConfig address.
    - `start_block`: The first L1 block of the rollup history.
    - `submitter`: Value of `INDEXER_OPTIMISM_L1_BATCH_SUBMITTER`, used only if the seed at `start_block`
      cannot be read.
    - `range_size`: Max number of L1 blocks in one ranged `eth_getLogs` request.
    - `json_rpc_named_arguments`: Configuration parameters for the L1 JSON RPC connection.
    - `opts`:
      - `from` - the first L1 block the caller will process (`start_block` by default). The history
        is read from there (but not above the finalized block) when the batcher there is readable
        or unchanged since then; otherwise the whole history is read.
      - `retries` - number of attempts for a request and for reading a history of a finalized start
        block the finalized state agrees with (unlimited by default). Reading SystemConfig state is
        attempted at most `Helper.finite_retries_number()` times.

    ## Returns
    - `{:ok, timeline}` on success.
    - `{:error, reason}` if the seed is unknown or the history cannot be read after all attempts.
  """
  @spec init(
          String.t(),
          non_neg_integer(),
          String.t() | nil,
          pos_integer(),
          EthereumJSONRPC.json_rpc_named_arguments(),
          keyword()
        ) :: {:ok, t()} | {:error, String.t()}
  def init(contract, start_block, submitter, range_size, json_rpc_named_arguments, opts \\ []) do
    retries = Keyword.get(opts, :retries, Helper.infinite_retries_number())
    params = {String.downcase(contract), start_block, submitter, range_size}
    read = &read_history(params, &1, json_rpc_named_arguments, retries, 0)

    read_known(read, Keyword.get(opts, :from, start_block), start_block)
  end

  @doc """
    Returns the batcher authorized at the given L1 block, or `nil` before the start block, where
    nobody is. Blocks outside the timeline must be added with `sync/3` first.
  """
  @spec address_at(t(), non_neg_integer()) :: String.t() | nil
  def address_at(%__MODULE__{start_block: start_block}, block_number)
      when is_integer(block_number) and block_number < start_block,
      do: nil

  def address_at(%__MODULE__{first_block: first_block, through: through} = timeline, block_number)
      when is_integer(block_number) and block_number >= first_block and block_number <= through do
    case Enum.find(timeline.updates, fn {update_block_number, _} -> update_block_number <= block_number end) do
      {_, batcher} -> batcher
      nil -> timeline.seed
    end
  end

  @doc """
    Extends the timeline over a chunk of fetched L1 blocks.

    Chunk blocks below the timeline's first block need the history from there, which is added to the
    timeline. Chunk blocks that were read before must have the same hashes. Then the blocks read before
    become final up to the L1 finalized block, and the updates of the newer blocks are read by the
    hashes of the chunk blocks; blocks between the timeline and the chunk are read by their current
    hashes.

    ## Parameters
    - `timeline`: The current timeline.
    - `blocks`: Params of the chunk blocks (`number`, `hash`, `parent_hash`).
    - `json_rpc_named_arguments`: Configuration parameters for the L1 JSON RPC connection.

    ## Returns
    - `{:ok, timeline}` covering the whole chunk.
    - `{:reorg, block_number}` if the unfinalized blocks read before are not on the current L1 chain.
      They must be processed again from `block_number` (the first unfinalized block) after `truncate/2`
      to the block before it.
    - `{:error, reason}` if a request failed or the chunk is inconsistent. The caller should fetch the
      chunk again and retry with the same timeline.
  """
  @spec sync(t(), [map()], EthereumJSONRPC.json_rpc_named_arguments()) ::
          {:ok, t()} | {:reorg, non_neg_integer()} | {:error, String.t()}
  def sync(timeline, [], _json_rpc_named_arguments), do: {:ok, timeline}

  def sync(timeline, blocks, json_rpc_named_arguments) do
    numbers = Enum.map(blocks, & &1.number)
    last = Enum.max(numbers)

    with {:ok, timeline} <- cover(timeline, Enum.min(numbers), json_rpc_named_arguments),
         :ok <- validate_processed(timeline, blocks),
         {:ok, timeline} <- finalize(timeline, last, json_rpc_named_arguments) do
      sync_unfinalized(timeline, blocks, last, json_rpc_named_arguments)
    end
  end

  @doc """
    Drops the updates above `block_number`, but not the finalized ones, after an L1 reorg. The next
    `sync/3` reads these blocks again. The hashes kept up to `block_number` let it detect a reorg that
    started below that block, as a reorg can be reported above its first replaced block.
  """
  @spec truncate(t(), non_neg_integer()) :: t()
  def truncate(%__MODULE__{} = timeline, block_number) do
    through = timeline.through |> min(block_number) |> max(timeline.finalized)

    %{
      timeline
      | updates: Enum.filter(timeline.updates, fn {number, _} -> number <= through end),
        through: through,
        hashes: Map.reject(timeline.hashes, fn {number, _} -> number > through end)
    }
  end

  # The configured submitter is the batcher at the start block, so a history whose batcher at a later
  # first block is unknown is read from the start block instead.
  defp read_known(read, from, start_block) do
    case read.(from) do
      {:unknown_seed, first_block} ->
        Logger.info(
          "The batcher at L1 block ##{first_block} cannot be read from SystemConfig, so the batcher updates " <>
            "are read from the start block ##{start_block}."
        )

        read.(start_block)

      result ->
        result
    end
  end

  # Reads the history from `from` (not above the finalized block) again while the start block is not
  # finalized or the finalized state does not confirm it.
  defp read_history({contract, start_block, _, _} = params, from, json_rpc_named_arguments, retries, done) do
    with {:ok, %{number: finalized, hash: finalized_hash}} <- finalized_header(json_rpc_named_arguments, retries),
         # a reorg could replace the seed and the updates of an unfinalized start block
         :ok <- start_block_finalized(start_block, finalized),
         first_block = from |> min(finalized) |> max(start_block),
         # read before the long history scan, while a pruning node still has the finalized state
         {:ok, finalized_batcher} <- finalized_batcher(contract, finalized, json_rpc_named_arguments, retries),
         {:ok, timeline} <-
           read_range(params, first_block, {finalized, finalized_batcher}, json_rpc_named_arguments, retries) do
      {:ok, %{timeline | hashes: %{finalized => finalized_hash}}}
    else
      {:incomplete, message} when done + 1 < retries ->
        Logger.error("#{message} Retrying...")
        Helper.pause_before_retry(done)
        read_history(params, from, json_rpc_named_arguments, retries, done + 1)

      {:incomplete, message} ->
        {:error, message}

      error ->
        error
    end
  end

  # Reads the updates from `first_block` to the final block `last`, where they must lead to `last_batcher`.
  defp read_range(
         {contract, start_block, submitter, range_size} = params,
         first_block,
         {last, last_batcher},
         json_rpc_named_arguments,
         retries
       ) do
    with {:ok, updates} <-
           fetch_updates_by_range(contract, first_block, last, range_size, json_rpc_named_arguments, retries),
         {:ok, seed} <- seed(params, first_block, {last, updates, last_batcher}, json_rpc_named_arguments, retries),
         timeline = %__MODULE__{
           contract: contract,
           start_block: start_block,
           first_block: first_block,
           submitter: submitter,
           range_size: range_size,
           seed: seed,
           finalized: last,
           through: last,
           updates: updates
         },
         :ok <- verify_history(timeline, last_batcher, json_rpc_named_arguments, retries) do
      {:ok, timeline}
    end
  end

  # Blocks processed again below the first block (e.g. requeued for a blob retry) need the history
  # from there. Blocks before the start block need none, as nobody is authorized there.
  defp cover(timeline, block_number, json_rpc_named_arguments) do
    from = max(block_number, timeline.start_block)

    if from >= timeline.first_block do
      {:ok, timeline}
    else
      Logger.info("Batcher updates are read from L1 block ##{from}, which is processed again.")
      read_known(&extend(timeline, &1, json_rpc_named_arguments), from, timeline.start_block)
    end
  end

  # Adds the final history from `from` up to the first block, where it must lead to the batcher known
  # there. The unfinalized blocks read before keep their hashes, so a reorg replacing them is still
  # detected. The caller retries an incomplete history with its chunk.
  defp extend(timeline, from, json_rpc_named_arguments) do
    params = {timeline.contract, timeline.start_block, timeline.submitter, timeline.range_size}
    known = {timeline.first_block, address_at(timeline, timeline.first_block)}

    case read_range(params, from, known, json_rpc_named_arguments, Helper.finite_retries_number()) do
      {:ok, older} ->
        {:ok,
         %{timeline | first_block: from, seed: older.seed, updates: merge_updates(timeline.updates, older.updates)}}

      {:incomplete, message} ->
        {:error, message}

      other ->
        other
    end
  end

  defp start_block_finalized(start_block, finalized) when finalized < start_block,
    do: {:incomplete, "L1 start block ##{start_block} is not finalized yet (the finalized block is ##{finalized})."}

  defp start_block_finalized(_start_block, _finalized), do: :ok

  defp finalized_batcher(contract, finalized, json_rpc_named_arguments, retries) do
    case batcher_at(contract, finalized, json_rpc_named_arguments, min(retries, Helper.finite_retries_number())) do
      {:ok, batcher} ->
        {:ok, batcher}

      :error ->
        {:incomplete,
         "Cannot read SystemConfig.batcherHash at the finalized L1 block ##{finalized} to check the batcher updates."}
    end
  end

  # The history must agree with the batcher at its last block, read from SystemConfig's state at the
  # finalized block or known from the timeline extended back, and with SystemConfig's state around
  # every update (before and at its block), which needs historical state. Without historical state an
  # update missing between two found updates cannot be detected.
  defp verify_history(timeline, last_batcher, json_rpc_named_arguments, retries) do
    case compare(timeline, timeline.through, {:ok, last_batcher}) do
      :ok ->
        check_updates(timeline, json_rpc_named_arguments, min(retries, Helper.finite_retries_number()))

      {:unset, block_number} ->
        {:incomplete,
         "SystemConfig.batcherHash is not set at the finalized L1 block ##{block_number}, so the batcher updates cannot be checked."}

      incomplete ->
        incomplete
    end
  end

  defp check_updates(timeline, json_rpc_named_arguments, attempts) do
    timeline.updates
    |> Enum.flat_map(fn {block_number, _} -> [block_number - 1, block_number] end)
    |> Enum.filter(&(&1 >= timeline.first_block and &1 < timeline.through))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn block_number, :ok ->
      case check_batcher(timeline, block_number, json_rpc_named_arguments, attempts) do
        :ok ->
          {:cont, :ok}

        {:unset, _} ->
          {:cont, :ok}

        {:unreadable, _} ->
          Logger.warning(
            "Historical SystemConfig state is not readable, so the batcher updates before L1 block " <>
              "##{timeline.through} are checked only by their result at that block."
          )

          {:halt, :ok}

        incomplete ->
          {:halt, incomplete}
      end
    end)
  end

  defp check_batcher(timeline, block_number, json_rpc_named_arguments, attempts) do
    compare(timeline, block_number, batcher_at(timeline.contract, block_number, json_rpc_named_arguments, attempts))
  end

  defp compare(timeline, block_number, batcher_result) do
    expected = address_at(timeline, block_number)

    case batcher_result do
      # no batcher is set in SystemConfig at this block, e.g. before its initialization
      {:ok, @zero_address} when expected != @zero_address ->
        {:unset, block_number}

      {:ok, ^expected} ->
        :ok

      {:ok, batcher} ->
        {:incomplete,
         "SystemConfig batcher updates look incomplete: they lead to #{expected} at L1 block ##{block_number}, " <>
           "but SystemConfig.batcherHash is #{batcher}."}

      :error ->
        {:unreadable, block_number}
    end
  end

  # Unfinalized blocks processed again must be the ones whose updates were read.
  defp validate_processed(timeline, blocks) do
    stale =
      Enum.find(blocks, fn %{number: number, hash: hash} ->
        number > timeline.finalized and number <= timeline.through and
          Map.get(timeline.hashes, number) != downcase(hash)
      end)

    if is_nil(stale),
      do: :ok,
      else: reorg(timeline, "L1 block ##{stale.number} is not the one whose batcher updates were read before.")
  end

  defp reorg(timeline, message) do
    Logger.warning(
      "#{message} Batcher updates of unfinalized L1 blocks are read again from ##{timeline.finalized + 1}."
    )

    {:reorg, timeline.finalized + 1}
  end

  # Blocks read before become final up to the L1 finalized block, if they are the finalized ones.
  defp finalize(%__MODULE__{through: through} = timeline, last, _json_rpc_named_arguments) when last <= through,
    do: {:ok, timeline}

  defp finalize(timeline, _last, json_rpc_named_arguments) do
    with {:ok, finalized, through_header} <- finality(timeline.through, json_rpc_named_arguments),
         block_number = min(finalized.number, timeline.through),
         true <- block_number > timeline.finalized,
         {:ok, final_hash} <- final_hash(block_number, finalized, through_header) do
      if Map.get(timeline.hashes, block_number) == final_hash do
        {:ok,
         %{
           timeline
           | finalized: block_number,
             hashes: Map.reject(timeline.hashes, fn {number, _} -> number < block_number end)
         }}
      else
        reorg(
          timeline,
          "Finalized L1 block ##{block_number} (#{final_hash}) is not the one whose batcher updates were read."
        )
      end
    else
      # nothing to finalize, or the finalized chain is not readable now; newer blocks are read by hash anyway
      _ -> {:ok, timeline}
    end
  end

  # The finalized block and the block `through` as seen by one node: when that node has finalized a
  # later block, its block `through` is final too.
  defp finality(through, json_rpc_named_arguments) do
    requests = [
      request(%{id: 0, method: "eth_getBlockByNumber", params: ["finalized", false]}),
      request(%{id: 1, method: "eth_getBlockByNumber", params: [integer_to_quantity(through), false]})
    ]

    with {:ok, [finalized, through_header]} <- batch_results(requests, json_rpc_named_arguments),
         {:ok, finalized} <- to_finalized_header(finalized) do
      {:ok, finalized, through_header}
    end
  end

  defp final_hash(block_number, %{number: block_number, hash: hash}, _through_header), do: {:ok, hash}

  defp final_hash(block_number, _finalized, through_header) do
    case to_header({block_number, through_header}) do
      {:ok, %{hash: hash}} -> {:ok, hash}
      error -> error
    end
  end

  # The finalized part can already cover the chunk.
  defp sync_unfinalized(%__MODULE__{through: through} = timeline, _blocks, last, _json_rpc_named_arguments)
       when last <= through,
       do: {:ok, timeline}

  defp sync_unfinalized(timeline, blocks, last, json_rpc_named_arguments) do
    first = timeline.through + 1

    chunk_headers =
      blocks
      |> Enum.filter(&(&1.number >= first and &1.number <= last))
      |> Enum.sort_by(& &1.number)
      |> Enum.map(&%{number: &1.number, hash: downcase(&1.hash), parent_hash: downcase(&1.parent_hash)})

    chunk_first = chunk_headers |> List.first(%{number: last + 1}) |> Map.get(:number)

    with {:ok, gap_headers} <- fetch_headers(first..(chunk_first - 1)//1, json_rpc_named_arguments),
         headers = gap_headers ++ chunk_headers,
         :ok <- validate_headers(timeline, headers, first..last),
         {:ok, logs} <- fetch_logs_by_hashes(timeline.contract, headers, json_rpc_named_arguments) do
      {:ok,
       %{
         timeline
         | updates: merge_updates(timeline.updates, to_updates(logs, timeline.contract)),
           through: last,
           hashes: Map.merge(timeline.hashes, Map.new(headers, &{&1.number, &1.hash}))
       }}
    end
  end

  # Checks that the headers are the consecutive blocks of the range linked by their parent hashes,
  # and that the first one is the child of the last block read before.
  defp validate_headers(timeline, [first_header | _] = headers, range) do
    linked? =
      headers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [parent, child] -> is_binary(parent.hash) and child.parent_hash == parent.hash end)

    cond do
      Enum.map(headers, & &1.number) != Enum.to_list(range) or not linked? ->
        {:error, "L1 blocks #{inspect(range)} do not form a chain. Probably, the L1 chain changed while reading them."}

      first_header.parent_hash == Map.get(timeline.hashes, timeline.through) ->
        :ok

      timeline.through > timeline.finalized ->
        reorg(
          timeline,
          "L1 block ##{first_header.number} is not a child of the L1 block whose batcher updates were read before."
        )

      true ->
        {:error, "L1 block ##{first_header.number} is not a child of the finalized L1 block ##{timeline.through}."}
    end
  end

  # The first block's value is the seed by definition. Without updates since the first block, the last
  # block of the history (the finalized block, or the first block of the timeline extended back) has
  # the same value, which needs no historical state. The configured submitter is the batcher at the
  # start block, so a later first block without a readable seed needs the history from the start block.
  defp seed(
         {contract, start_block, submitter, _range_size},
         first_block,
         {last, updates, last_batcher},
         json_rpc_named_arguments,
         retries
       ) do
    attempts = min(retries, Helper.finite_retries_number())
    submitter = if first_block == start_block, do: configured_submitter(submitter)

    case readable_batcher(contract, first_block, json_rpc_named_arguments, attempts) ||
           unchanged_seed(last, updates, last_batcher) do
      {block_number, batcher} ->
        if not is_nil(submitter) and submitter != batcher do
          Logger.warning(
            "INDEXER_OPTIMISM_L1_BATCH_SUBMITTER (#{submitter}) is ignored: " <>
              "SystemConfig.batcherHash at L1 block ##{block_number} is #{batcher}."
          )
        end

        {:ok, batcher}

      nil when first_block > start_block ->
        {:unknown_seed, first_block}

      nil when not is_nil(submitter) ->
        Logger.info(
          "Cannot read SystemConfig.batcherHash for L1 block ##{start_block}, so INDEXER_OPTIMISM_L1_BATCH_SUBMITTER " <>
            "(#{submitter}) is used as the batcher at this block."
        )

        {:ok, submitter}

      nil ->
        {:error,
         "Cannot determine the batcher at L1 block ##{start_block}: SystemConfig.batcherHash is not readable " <>
           "(the batcher was changed after the start block, so historical L1 state is needed) " <>
           "and INDEXER_OPTIMISM_L1_BATCH_SUBMITTER is not set."}
    end
  end

  # A zero address is not a usable batcher.
  defp configured_submitter(submitter) do
    if Helper.address_correct?(submitter) and String.downcase(submitter) != @zero_address,
      do: String.downcase(submitter)
  end

  defp unchanged_seed(last, [], batcher) when batcher != @zero_address, do: {last, batcher}
  defp unchanged_seed(_last, _updates, _batcher), do: nil

  defp readable_batcher(contract, block_number, json_rpc_named_arguments, attempts) do
    case batcher_at(contract, block_number, json_rpc_named_arguments, attempts) do
      {:ok, batcher} when batcher != @zero_address -> {block_number, batcher}
      _ -> nil
    end
  end

  defp batcher_at(contract, block_number, json_rpc_named_arguments, retries) do
    request =
      request(%{
        id: 0,
        method: "eth_call",
        params: [%{to: contract, data: @batcher_hash_selector}, integer_to_quantity(block_number)]
      })

    error_message = &"Cannot read SystemConfig.batcherHash at L1 block ##{block_number}. Error: #{inspect(&1)}"

    with {:ok, "0x" <> word} <-
           Helper.repeated_call(&json_rpc/2, [request, json_rpc_named_arguments], error_message, retries),
         {:ok, <<0::96, batcher::binary-size(20)>>} <- Base.decode16(word, case: :mixed) do
      {:ok, "0x" <> Base.encode16(batcher, case: :lower)}
    else
      _ -> :error
    end
  end

  defp finalized_header(json_rpc_named_arguments, retries) do
    error_message = &"Cannot fetch the finalized L1 block. Error: #{inspect(&1)}"
    Helper.repeated_call(&fetch_finalized_header/1, [json_rpc_named_arguments], error_message, retries)
  end

  defp fetch_finalized_header(json_rpc_named_arguments) do
    request = request(%{id: 0, method: "eth_getBlockByNumber", params: ["finalized", false]})

    case json_rpc(request, json_rpc_named_arguments) do
      {:ok, result} -> to_finalized_header(result)
      error -> error
    end
  end

  defp to_finalized_header(%{"number" => number, "hash" => hash}) when is_binary(number) and is_binary(hash),
    do: {:ok, %{number: quantity_to_integer(number), hash: String.downcase(hash)}}

  defp to_finalized_header(result), do: {:error, "Unexpected finalized L1 block: #{inspect(result)}"}

  defp fetch_updates_by_range(contract, from, to, range_size, json_rpc_named_arguments, retries) do
    from..to//range_size
    |> map_ok(fn range_start ->
      range_end = min(range_start + range_size - 1, to)

      error_message =
        &"Cannot fetch SystemConfig batcher updates in L1 blocks #{range_start}..#{range_end}: #{inspect(&1)}"

      Helper.repeated_call(
        &fetch_range_logs/4,
        [contract, range_start, range_end, json_rpc_named_arguments],
        error_message,
        retries
      )
    end)
    |> case do
      {:ok, logs} -> {:ok, logs |> Enum.concat() |> to_updates(contract)}
      {:error, reason} -> {:error, "Cannot fetch SystemConfig batcher updates: #{inspect(reason)}"}
    end
  end

  # The logs are requested together with the header of the range's last block, so the node that
  # answers the batch must have the whole range.
  defp fetch_range_logs(contract, from, to, json_rpc_named_arguments) do
    requests = [
      request(%{
        id: 0,
        method: "eth_getLogs",
        params: [
          %{
            fromBlock: integer_to_quantity(from),
            toBlock: integer_to_quantity(to),
            address: contract,
            topics: @batcher_update_topics
          }
        ]
      }),
      request(%{id: 1, method: "eth_getBlockByNumber", params: [integer_to_quantity(to), false]})
    ]

    with {:ok, [logs, header]} <- batch_results(requests, json_rpc_named_arguments),
         true <- is_list(logs),
         {:ok, %{number: ^to}} <- to_header({to, header}) do
      {:ok, Enum.filter(logs, &(log_block_number(&1) in from..to))}
    else
      {:error, _} = error -> error
      other -> {:error, "Incomplete answer: #{inspect(other)}"}
    end
  end

  defp fetch_headers(range, json_rpc_named_arguments) do
    range
    |> Enum.chunk_every(@rpc_batch_size)
    |> map_ok(&fetch_header_batch(&1, json_rpc_named_arguments))
    |> case do
      {:ok, headers} -> {:ok, Enum.concat(headers)}
      error -> error
    end
  end

  defp fetch_header_batch(block_numbers, json_rpc_named_arguments) do
    requests =
      Enum.with_index(block_numbers, fn block_number, id ->
        request(%{id: id, method: "eth_getBlockByNumber", params: [integer_to_quantity(block_number), false]})
      end)

    with {:ok, results} <- batch_results(requests, json_rpc_named_arguments) do
      block_numbers
      |> Enum.zip(results)
      |> map_ok(&to_header/1)
    end
  end

  defp to_header({block_number, %{"number" => quantity, "hash" => hash, "parentHash" => parent_hash}})
       when is_binary(quantity) do
    if quantity_to_integer(quantity) == block_number do
      {:ok, %{number: block_number, hash: downcase(hash), parent_hash: downcase(parent_hash)}}
    else
      {:error, "L1 RPC returned block #{quantity} instead of ##{block_number}"}
    end
  end

  defp to_header({block_number, result}), do: {:error, "L1 block ##{block_number} is not available: #{inspect(result)}"}

  defp fetch_logs_by_hashes(contract, headers, json_rpc_named_arguments) do
    headers
    |> Enum.chunk_every(@rpc_batch_size)
    |> map_ok(&fetch_logs_batch(contract, &1, json_rpc_named_arguments))
    |> case do
      {:ok, logs} -> {:ok, Enum.concat(logs)}
      error -> error
    end
  end

  defp fetch_logs_batch(contract, headers, json_rpc_named_arguments) do
    requests =
      Enum.with_index(headers, fn header, id ->
        request(%{
          id: id,
          method: "eth_getLogs",
          params: [%{blockHash: header.hash, address: contract, topics: @batcher_update_topics}]
        })
      end)

    with {:ok, results} <- batch_results(requests, json_rpc_named_arguments),
         {:ok, logs} <- headers |> Enum.zip(results) |> map_ok(&block_logs/1) do
      {:ok, Enum.concat(logs)}
    end
  end

  defp block_logs({header, logs}) do
    if is_list(logs) and Enum.all?(logs, &(downcase(&1["blockHash"]) == header.hash)) do
      {:ok, logs}
    else
      {:error,
       "Cannot fetch SystemConfig batcher updates of L1 block ##{header.number} (#{header.hash}): #{inspect(logs)}"}
    end
  end

  # Sends a JSON-RPC batch and returns the results in the order of the requests.
  # An error in any of the responses fails the whole batch.
  defp batch_results(requests, json_rpc_named_arguments) do
    case json_rpc(requests, json_rpc_named_arguments) do
      {:ok, responses} when is_list(responses) ->
        responses_by_id = Map.new(responses, &{&1.id, &1})
        map_ok(requests, &response_result(responses_by_id[&1.id]))

      other ->
        {:error, "L1 RPC batch request failed: #{inspect(other)}"}
    end
  end

  defp response_result(%{result: result}), do: {:ok, result}
  defp response_result(response), do: {:error, "L1 RPC request failed: #{inspect(response)}"}

  # Applies `fun` to the elements in order and collects the results until the first error.
  defp map_ok(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  # Converts ConfigUpdate logs into `{block_number, batcher}` pairs sorted in descending order.
  defp to_updates(logs, contract) do
    logs
    |> Enum.filter(&is_integer(log_block_number(&1)))
    |> Enum.sort_by(&{log_block_number(&1), quantity_to_integer(&1["logIndex"] || "0x0")})
    |> Enum.reduce(%{}, fn log, acc ->
      case decode_update(log, contract) do
        {:ok, batcher} -> Map.put(acc, log_block_number(log), batcher)
        :error -> acc
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  defp merge_updates(updates, new_updates) do
    (updates ++ new_updates)
    |> Map.new()
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  # Mirrors op-node: three topics, and data holding exactly one zero-padded address
  # behind the ABI offset and length words.
  defp decode_update(log, contract) do
    with false <- log["removed"] == true,
         ^contract <- downcase(log["address"]),
         @batcher_update_topics <- Enum.map(log["topics"] || [], &downcase/1),
         "0x" <> data <- log["data"],
         {:ok, <<32::256, 32::256, 0::96, batcher::binary-size(20)>>} <- Base.decode16(data, case: :mixed) do
      {:ok, "0x" <> Base.encode16(batcher, case: :lower)}
    else
      _ ->
        Logger.warning(
          "Ignoring a SystemConfig log in L1 block ##{log_block_number(log)} which is not a valid batcher update: " <>
            inspect(log)
        )

        :error
    end
  end

  defp log_block_number(%{"blockNumber" => block_number}) when is_binary(block_number),
    do: quantity_to_integer(block_number)

  defp log_block_number(_log), do: nil

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_value), do: nil
end
