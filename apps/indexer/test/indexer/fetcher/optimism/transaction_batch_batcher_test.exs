if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.TransactionBatchBatcherTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import ExUnit.CaptureLog
    import Mox

    alias Indexer.Fetcher.Optimism
    alias Indexer.Fetcher.Optimism.{BatcherTimeline, BlobRetryQueue, TransactionBatch}
    alias Indexer.RollupReorgMonitorQueue

    @counter_type "optimism_batches_fetcher_last_l1_block_hash"
    @l1_url "http://l1.example"
    @contract "0x1111111111111111111111111111111111111111"
    @inbox "0x2222222222222222222222222222222222222222"
    @elsewhere "0x3333333333333333333333333333333333333333"
    @a "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    @b "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    @zero_address "0x0000000000000000000000000000000000000000"
    @zero_word "0x" <> String.duplicate("0", 64)
    @event "0x" <> Base.encode16(ExKeccak.hash_256("ConfigUpdate(uint256,uint8,bytes)"), case: :lower)
    @start 100

    setup :verify_on_exit!

    setup do
      chain =
        start_supervised!({Agent,
         fn ->
           %{
             head: 106,
             safe: 104,
             finalized: 102,
             fork_from: nil,
             fork: 0,
             # {block, fork, batcher} rotations emitted by SystemConfig
             updates: [],
             # SystemConfig.batcherHash value history as {from_block, address}
             batcher: [{0, @a}],
             transactions: []
           }
         end})

      # the L1 node answers through the HTTP transport, which uses the mocked Tesla adapter in tests
      stub(Explorer.Mock.TeslaAdapter, :call, fn %Tesla.Env{body: body} = env, _options ->
        response = body |> Jason.decode!() |> respond(Agent.get(chain, & &1)) |> Jason.encode!()
        {:ok, %Tesla.Env{env | status: 200, body: response, headers: [{"content-type", "application/json"}]}}
      end)

      BlobRetryQueue.clear()
      drain_reorg_queue()

      %{rpc: Indexer.Helper.json_rpc_named_arguments(@l1_url), chain: chain}
    end

    describe "handle_info(:continue, state)" do
      test "accepts frames only from the batcher authorized at each L1 block", ctx do
        rotate(ctx, 105, @b)

        add_transactions(ctx, [
          transaction(104, 1, @a),
          transaction(104, 2, @b),
          # the old key after the rotation and the new key before it are both rejected
          transaction(105, 3, @a),
          transaction(105, 4, @b),
          transaction(106, 5, @b, to: @elsewhere)
        ])

        assert {:noreply, state} = TransactionBatch.handle_info(:continue, state(ctx, 103, 106))
        assert channels(state) == [1, 4]
      end

      test "a reorg inside the processed chunk rewinds to the block before it and re-reads the moved rotation",
           ctx do
        rotate(ctx, 105, @b)
        add_transactions(ctx, [transaction(104, 1, @a), transaction(105, 2, @b)])

        RollupReorgMonitorQueue.push(105, TransactionBatch)
        assert {:noreply, rewound} = TransactionBatch.handle_info(:continue, state(ctx, 103, 106))
        assert rewound.start_block == 105

        # on the replacing fork the rotation is one block later
        Agent.update(ctx.chain, fn chain ->
          %{chain | fork_from: 105, fork: 1, updates: [{106, 1, @b}], batcher: [{0, @a}, {106, @b}]}
        end)

        add_transactions(ctx, [
          transaction(105, 3, @a, fork: 1),
          transaction(105, 4, @b, fork: 1),
          transaction(106, 5, @b, fork: 1)
        ])

        assert {:noreply, resumed} = TransactionBatch.handle_info(:continue, rewound)
        assert resumed.start_block == 107
        assert channels(resumed) == [1, 3, 5]
      end

      test "a reorg above the processed chunk does not rewind it", ctx do
        RollupReorgMonitorQueue.push(200, TransactionBatch)
        assert {:noreply, state} = TransactionBatch.handle_info(:continue, state(ctx, 103, 106))
        assert state.start_block == 107
      end

      test "a reorg reported above its first replaced block also processes the blocks below it again", ctx do
        rotate(ctx, 105, @b)
        add_transactions(ctx, [transaction(104, 1, @a), transaction(105, 2, @b)])

        assert {:noreply, processed} = TransactionBatch.handle_info(:continue, state(ctx, 103, 106))
        assert channels(processed) == [1, 2]

        # the replacing fork starts at 105 and moves the rotation to 106, but the reorg monitor only sees
        # that the hash of the head block 106 changed
        Agent.update(ctx.chain, fn chain ->
          %{chain | fork_from: 105, fork: 1, updates: [{106, 1, @b}], batcher: [{0, @a}, {106, @b}]}
        end)

        add_transactions(ctx, [transaction(105, 3, @a, fork: 1), transaction(106, 4, @b, fork: 1)])
        RollupReorgMonitorQueue.push(106, TransactionBatch)

        state =
          Enum.reduce(1..3, processed, fn _, state ->
            assert {:noreply, state} = TransactionBatch.handle_info(:continue, state)
            state
          end)

        assert channels(state) == [1, 3, 4]
      end

      test "an iteration without new blocks keeps the scan position", ctx do
        # e.g. right after startup, when the safe block is below the start block
        assert {:noreply, state} = TransactionBatch.handle_info(:continue, state(ctx, 103, 101))
        assert state.start_block == 103
      end

      test "an iteration without new blocks waits for the next block", ctx do
        # the latest block is below the scan position, e.g. on a lagging node
        Agent.update(ctx.chain, &%{&1 | head: 105})

        assert {:noreply, _state} = TransactionBatch.handle_info(:continue, state(ctx, 107, 101))
        refute_receive :continue, 100
      end

      test "a reorg below the scan position of an iteration without new blocks rewinds to it", ctx do
        RollupReorgMonitorQueue.push(103, TransactionBatch)
        assert {:noreply, state} = TransactionBatch.handle_info(:continue, state(ctx, 105, 101))
        assert state.start_block == 103
      end

      test "a blob retry over unfinalized blocks of an unreported fork rescans them with that fork's rotation",
           ctx do
        rotate(ctx, 105, @b)
        add_transactions(ctx, [transaction(104, 1, @a), transaction(105, 2, @b)])

        assert {:noreply, processed} = TransactionBatch.handle_info(:continue, state(ctx, 103, 106))
        assert channels(processed) == [1, 2]

        # nobody reports the fork that moves the rotation one block later
        Agent.update(ctx.chain, fn chain ->
          %{chain | fork_from: 105, fork: 1, updates: [{106, 1, @b}], batcher: [{0, @a}, {106, @b}]}
        end)

        add_transactions(ctx, [transaction(105, 3, @a, fork: 1), transaction(106, 4, @b, fork: 1)])

        # a due blob retry rewinds into the unfinalized blocks and skips the first continuity check
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.enqueue(105, "blob", "transaction")
        Agent.update(BlobRetryQueue, &put_in(&1, [105, :last_attempt_at], 0))

        assert {:noreply, rewound} = TransactionBatch.handle_info(:continue, processed)
        # the first block above the finalized one (102)
        assert rewound.start_block == 103

        assert {:noreply, rescanned} = TransactionBatch.handle_info(:continue, rewound)
        assert channels(rescanned) == [1, 3, 4]
      end

      test "a blob retry below the history read on a restart still detects an unreported fork", ctx do
        rotate(ctx, 105, @b)
        add_transactions(ctx, [transaction(104, 1, @a), transaction(105, 2, @b)])

        # the restart resumed at the finalized block 102
        assert {:noreply, processed} = TransactionBatch.handle_info(:continue, state(ctx, 103, 106, from: 102))
        assert channels(processed) == [1, 2]

        # nobody reports the fork that moves the rotation one block later
        Agent.update(ctx.chain, fn chain ->
          %{chain | fork_from: 105, fork: 1, updates: [{106, 1, @b}], batcher: [{0, @a}, {106, @b}]}
        end)

        add_transactions(ctx, [transaction(105, 3, @a, fork: 1), transaction(106, 4, @b, fork: 1)])

        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.enqueue(101, "blob", "transaction")
        Agent.update(BlobRetryQueue, &put_in(&1, [101, :last_attempt_at], 0))

        state =
          Enum.reduce(1..3, processed, fn _, state ->
            assert {:noreply, state} = TransactionBatch.handle_info(:continue, state)
            state
          end)

        # the frame of the replaced block 105 is dropped
        assert channels(state) == [1, 3, 4]
      end
    end

    describe "handle_info(:init_with_delay, state)" do
      setup ctx do
        # like Mantle's SystemConfig 1.4.0: no startBlock() and batchInbox() getters, and an unusable
        # batcherHash at the start block followed by a rotation
        rotate(ctx, 101, @b)
        Agent.update(ctx.chain, &%{&1 | batcher: [{0, @zero_address}, {101, @b}]})

        # the fetcher waits until the L1 reorg monitor has a state
        start_supervised!(%{
          id: :l1_reorg_monitor,
          start: {Agent, :start_link, [fn -> %{started: true} end, [name: Indexer.Fetcher.RollupL1ReorgMonitor]]}
        })

        :ok
      end

      test "seeds the timeline with INDEXER_OPTIMISM_L1_BATCH_SUBMITTER when SystemConfig cannot tell", ctx do
        configure(submitter: @a)

        assert {:noreply, state} =
                 TransactionBatch.handle_info(:init_with_delay, %{json_rpc_named_arguments_l2: ctx.rpc})

        assert BatcherTimeline.address_at(state.batcher_timeline, 100) == @a
        assert BatcherTimeline.address_at(state.batcher_timeline, 101) == @b
      end

      test "stops and names the missing setting when the batcher at the start block is unknown", ctx do
        configure(submitter: nil)

        log =
          capture_log(fn ->
            assert {:stop, :normal, _} =
                     TransactionBatch.handle_info(:init_with_delay, %{json_rpc_named_arguments_l2: ctx.rpc})
          end)

        assert log =~ "INDEXER_OPTIMISM_L1_BATCH_SUBMITTER"
      end

      test "a restart reads the batcher history from the last processed L1 block", ctx do
        configure(submitter: nil)
        Optimism.set_last_block_hash(canonical_hash(Agent.get(ctx.chain, & &1), 101), @counter_type)

        assert {:noreply, state} =
                 TransactionBatch.handle_info(:init_with_delay, %{json_rpc_named_arguments_l2: ctx.rpc})

        # the start block 100 is not read: the batcher at 101 comes from SystemConfig's state there
        assert state.batcher_timeline.first_block == 101
        assert BatcherTimeline.address_at(state.batcher_timeline, 101) == @b
      end
    end

    defp state(ctx, start_block, end_block, opts \\ []) do
      {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, Keyword.put(opts, :retries, 1))

      %{
        batch_inbox: @inbox,
        batcher_timeline: timeline,
        eip4844_blobs_api_url: "",
        eip4844_blobs_api_fallback_url: "",
        celestia_blobs_api_url: "",
        eigenda_blobs_api_url: "",
        alt_da_server_url: "",
        block_check_interval: 60_000,
        start_block: start_block,
        end_block: end_block,
        chunk_size: 4,
        incomplete_channels: %{},
        genesis_block_l2: 0,
        block_duration: 2,
        json_rpc_named_arguments: ctx.rpc,
        json_rpc_named_arguments_l2: ctx.rpc,
        chain_id_l1: 1
      }
    end

    defp channels(state) do
      state.incomplete_channels
      |> Map.keys()
      |> Enum.map(fn <<id::128>> -> id end)
      |> Enum.sort()
    end

    defp rotate(ctx, block, batcher) do
      Agent.update(ctx.chain, fn chain ->
        %{chain | updates: chain.updates ++ [{block, 0, batcher}], batcher: chain.batcher ++ [{block, batcher}]}
      end)
    end

    defp add_transactions(ctx, transactions),
      do: Agent.update(ctx.chain, &%{&1 | transactions: &1.transactions ++ transactions})

    defp transaction(block, id, from, opts \\ []),
      do: %{block: block, id: id, from: from, to: Keyword.get(opts, :to, @inbox), fork: Keyword.get(opts, :fork, 0)}

    defp configure(submitter: submitter) do
      for {module, config} <- [
            {TransactionBatch,
             [
               genesis_block_l2: 0,
               blocks_chunk_size: 4,
               inbox: @inbox,
               submitter: submitter,
               submitter_updates_range_size: 10
             ]},
            {Indexer.Fetcher.Optimism,
             [
               optimism_l1_rpc: @l1_url,
               optimism_l1_system_config: @contract,
               block_duration: 2,
               start_block_l1: @start
             ]}
          ] do
        original = Application.get_env(:indexer, module)
        Application.put_env(:indexer, module, Keyword.merge(original || [], config))
        on_exit(fn -> Application.put_env(:indexer, module, original) end)
      end
    end

    defp drain_reorg_queue do
      if RollupReorgMonitorQueue.pop(TransactionBatch), do: drain_reorg_queue(), else: :ok
    end

    defp respond(requests, chain) when is_list(requests), do: Enum.map(requests, &respond(&1, chain))

    defp respond(%{"id" => id} = request, chain) do
      case result(request, chain) do
        {:ok, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
        {:error, error} -> %{"jsonrpc" => "2.0", "id" => id, "error" => error}
      end
    end

    defp result(%{"method" => "eth_chainId"}, _chain), do: {:ok, "0x1"}

    defp result(%{"method" => "eth_getBlockByNumber", "params" => [tag, full?]}, chain)
         when tag in ["latest", "safe", "finalized"] do
      number = Map.fetch!(%{"latest" => chain.head, "safe" => chain.safe, "finalized" => chain.finalized}, tag)
      {:ok, block(chain, number, full?)}
    end

    defp result(%{"method" => "eth_getBlockByNumber", "params" => [number, full?]}, chain) do
      number = EthereumJSONRPC.quantity_to_integer(number)
      {:ok, if(number <= chain.head, do: block(chain, number, full?))}
    end

    defp result(%{"method" => "eth_getBlockByHash", "params" => [hash, full?]}, chain) do
      number = Enum.find(0..chain.head, &(canonical_hash(chain, &1) == hash))
      {:ok, if(number, do: block(chain, number, full?))}
    end

    defp result(%{"method" => "eth_getLogs", "params" => [%{"blockHash" => hash}]}, chain) do
      {:ok,
       for({block, fork, batcher} <- chain.updates, block_hash(block, fork) == hash, do: log(block, fork, batcher))}
    end

    defp result(%{"method" => "eth_getLogs", "params" => [%{"fromBlock" => from, "toBlock" => to}]}, chain) do
      range = EthereumJSONRPC.quantity_to_integer(from)..EthereumJSONRPC.quantity_to_integer(to)
      {:ok, for({block, fork, batcher} <- chain.updates, block in range, do: log(block, fork, batcher))}
    end

    # batcherHash()
    defp result(%{"method" => "eth_call", "params" => [%{"data" => "0xe81b2c6d"}, block]}, chain) do
      number =
        case block do
          %{"blockHash" => hash} -> Enum.find(0..chain.head, &(canonical_hash(chain, &1) == hash))
          quantity -> EthereumJSONRPC.quantity_to_integer(quantity)
        end

      {_, batcher} = chain.batcher |> Enum.filter(fn {from, _} -> from <= number end) |> Enum.max_by(&elem(&1, 0))
      {:ok, encode(<<0::96>> <> decode(batcher))}
    end

    # startBlock() and batchInbox() do not exist in Mantle's SystemConfig
    defp result(%{"method" => "eth_call"}, _chain), do: {:error, %{"code" => 3, "message" => "execution reverted"}}

    defp block(chain, number, full?) do
      transactions =
        for transaction <- chain.transactions,
            transaction.block == number,
            transaction.fork == fork_at(chain, number),
            do: transaction_json(chain, transaction)

      %{
        "baseFeePerGas" => "0x1",
        "difficulty" => "0x0",
        "extraData" => "0x",
        "gasLimit" => "0x1c9c380",
        "gasUsed" => "0x0",
        "hash" => canonical_hash(chain, number),
        "logsBloom" => "0x" <> String.duplicate("0", 512),
        "miner" => @zero_address,
        "mixHash" => @zero_word,
        "nonce" => "0x0000000000000000",
        "number" => EthereumJSONRPC.integer_to_quantity(number),
        "parentHash" => canonical_hash(chain, number - 1),
        "receiptsRoot" => @zero_word,
        "sha3Uncles" => @zero_word,
        "size" => "0x200",
        "stateRoot" => @zero_word,
        "timestamp" => EthereumJSONRPC.integer_to_quantity(1_700_000_000 + number * 12),
        "totalDifficulty" => "0x0",
        "transactions" => if(full?, do: transactions, else: Enum.map(transactions, & &1["hash"])),
        "transactionsRoot" => @zero_word,
        "uncles" => []
      }
    end

    defp transaction_json(chain, %{block: block, id: id} = transaction) do
      %{
        "blockHash" => canonical_hash(chain, block),
        "blockNumber" => EthereumJSONRPC.integer_to_quantity(block),
        "chainId" => "0x1",
        "from" => transaction.from,
        "gas" => "0x186a0",
        "gasPrice" => "0x1",
        "hash" => encode(<<block::128, id::128>>),
        # derivation version 0 and one frame of channel `id` that is not the last one
        "input" => encode(<<0::8, id::128, 0::16, 1::32, 7::8, 0::8>>),
        "nonce" => EthereumJSONRPC.integer_to_quantity(id),
        "r" => "0x1",
        "s" => "0x1",
        "to" => transaction.to,
        "transactionIndex" => EthereumJSONRPC.integer_to_quantity(id),
        "type" => "0x0",
        "v" => "0x1b",
        "value" => "0x0"
      }
    end

    defp log(block, fork, batcher) do
      %{
        "address" => @contract,
        "blockHash" => block_hash(block, fork),
        "blockNumber" => EthereumJSONRPC.integer_to_quantity(block),
        "data" => encode(<<32::256, 32::256, 0::96>> <> decode(batcher)),
        "logIndex" => "0x0",
        "removed" => false,
        "topics" => [@event, @zero_word, @zero_word],
        "transactionHash" => encode(<<block::256>>),
        "transactionIndex" => "0x0"
      }
    end

    defp fork_at(%{fork_from: from, fork: fork}, number) when is_integer(from) and number >= from, do: fork
    defp fork_at(_chain, _number), do: 0

    defp canonical_hash(chain, number), do: block_hash(number, fork_at(chain, number))
    defp block_hash(number, fork), do: encode(<<number + fork * 1_000_000::256>>)
    defp encode(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
    defp decode("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  end
end
