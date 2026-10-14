defmodule Indexer.Fetcher.Optimism.BatcherTimelineTest do
  use EthereumJSONRPC.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Indexer.Fetcher.Optimism.BatcherTimeline

  @contract "0x1111111111111111111111111111111111111111"
  @a "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @b "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @c "0xcccccccccccccccccccccccccccccccccccccccc"
  @zero_address "0x0000000000000000000000000000000000000000"
  @event "0x" <>
           Base.encode16(ExKeccak.hash_256("ConfigUpdate(uint256,uint8,bytes)"), case: :lower)
  @zero_topic "0x" <> String.duplicate("0", 64)
  @start 100

  setup :verify_on_exit!

  setup %{json_rpc_named_arguments: rpc} do
    owner = self()

    chain =
      start_supervised!({Agent,
       fn ->
         %{
           head: 140,
           finalized: 130,
           # blocks at and above `fork_from` belong to fork number `fork`
           fork_from: nil,
           fork: 0,
           logs: [],
           # ranged eth_getLogs requests miss the logs of these blocks, like a lagging node
           range_hidden: [],
           # ranged eth_getLogs requests return only the logs of canonical blocks
           range_canonical_only: false,
           # batches starting a range window at a key are served by a node whose head is the value
           lagging_windows: %{},
           # the node serves blocks of replaced forks by hash
           known_orphans: false,
           # batches without the finalized block request return the replaced (fork 0) header of these blocks
           stale_headers: [],
           # the next answers for the finalized block return these blocks instead (nil for a null answer)
           finalized_answers: [],
           # serving ranged eth_getLogs makes the state of the finalized block unreadable (pruned)
           prune_finalized_on_logs: false,
           # SystemConfig.batcherHash value history as {from_block, address}
           batcher: [{0, @a}],
           # historical state (eth_call) is available from this block on, except for `unreadable` blocks
           state_from: 0,
           unreadable: [],
           unavailable: [],
           failing: []
         }
       end})

    stub(EthereumJSONRPC.Mox, :json_rpc, fn request, _options ->
      send(owner, {:rpc, request})
      state = Agent.get(chain, & &1)

      case {request, state.finalized_answers} do
        {%{params: ["finalized", false]}, [number | rest]} ->
          Agent.update(chain, &%{&1 | finalized_answers: rest})
          {:ok, number && header(state, number)}

        _ ->
          if state.prune_finalized_on_logs and is_list(request) and
               Enum.any?(request, &(&1.method == "eth_getLogs")),
             do: Agent.update(chain, &%{&1 | unreadable: [&1.finalized | &1.unreadable]})

          respond(request, state)
      end
    end)

    %{rpc: rpc, chain: chain}
  end

  describe "init/6" do
    test "the seed is the SystemConfig value before any finalized update, not the env value",
         ctx do
      # a rotation that is not finalized yet must not leak into the history before it
      put_updates(ctx, [{135, @c}])

      log =
        capture_log(fn ->
          assert {:ok, timeline} =
                   BatcherTimeline.init(@contract, @start, @b, 10, ctx.rpc, retries: 1)

          assert BatcherTimeline.address_at(timeline, @start) == @a
          assert BatcherTimeline.address_at(timeline, 130) == @a
        end)

      assert log =~ "INDEXER_OPTIMISM_L1_BATCH_SUBMITTER"
    end

    test "without updates the seed needs no historical state", ctx do
      Agent.update(ctx.chain, &%{&1 | state_from: 125})

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)

      assert BatcherTimeline.address_at(timeline, @start) == @a
    end

    test "a history that cannot be checked against the finalized state is not accepted", ctx do
      Agent.update(ctx.chain, &%{&1 | unreadable: [130]})

      assert {:error, _} = BatcherTimeline.init(@contract, @start, @b, 10, ctx.rpc, retries: 1)
    end

    test "with updates the seed is the SystemConfig value at the start block, not the env value",
         ctx do
      put_updates(ctx, [{120, @c}])

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, @b, 10, ctx.rpc, retries: 1)

      assert BatcherTimeline.address_at(timeline, 119) == @a
      assert BatcherTimeline.address_at(timeline, 120) == @c
    end

    test "an update applies to its whole block, including the start block and range window edges",
         ctx do
      put_updates(ctx, [{100, @b}, {109, @c}, {110, @a}, {130, @b}])

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)

      assert Enum.map([100, 108, 109, 110, 129, 130], &BatcherTimeline.address_at(timeline, &1)) ==
               [@b, @b, @c, @a, @a, @b]
    end

    test "the last update in log order wins within a block", ctx do
      Agent.update(
        ctx.chain,
        &%{
          &1
          | logs: [log(105, @c, index: 3), log(105, @b, index: 1)],
            batcher: [{0, @a}, {105, @c}]
        }
      )

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)

      assert BatcherTimeline.address_at(timeline, 104) == @a
      assert BatcherTimeline.address_at(timeline, 105) == @c
    end

    test "malformed updates and logs of other contracts are ignored", ctx do
      address = decode(@b)

      logs = [
        log(101, @b, data: encode(<<32::256, 32::256, 1::8, 0::88>> <> address)),
        log(102, @b, data: encode(<<32::256, 32::256, 0::96>> <> address <> <<0::256>>)),
        log(103, @b, data: encode(<<64::256, 32::256, 0::96>> <> address)),
        log(104, @b, topics: [@event, @zero_topic, @zero_topic, @zero_topic]),
        log(105, @b, removed: true),
        log(106, @b, address: @c)
      ]

      Agent.update(ctx.chain, &%{&1 | logs: logs})

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)

      assert BatcherTimeline.address_at(timeline, 130) == @a
    end

    test "without historical state the env value seeds the blocks before the first update", ctx do
      put_updates(ctx, [{120, @c}])
      Agent.update(ctx.chain, &%{&1 | state_from: 125})

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, @b, 10, ctx.rpc, retries: 1)

      assert BatcherTimeline.address_at(timeline, 119) == @b
      assert BatcherTimeline.address_at(timeline, 120) == @c
    end

    test "an unknown start block batcher is an error", ctx do
      put_updates(ctx, [{120, @c}])
      Agent.update(ctx.chain, &%{&1 | state_from: 125})

      assert {:error, _} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)
    end

    test "a zero SystemConfig batcher cannot confirm the history", ctx do
      Agent.update(ctx.chain, &%{&1 | batcher: [{0, @zero_address}]})

      assert {:error, _} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)
      assert {:error, _} = BatcherTimeline.init(@contract, @start, @b, 10, ctx.rpc, retries: 1)

      assert {:error, _} =
               BatcherTimeline.init(@contract, @start, @zero_address, 10, ctx.rpc, retries: 1)
    end

    test "the finalized state is read before the history, which can outlive its retention", ctx do
      Agent.update(ctx.chain, &%{&1 | prune_finalized_on_logs: true})

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)

      assert BatcherTimeline.address_at(timeline, 130) == @a
    end

    test "waits until the start block is finalized", ctx do
      # a reorg could replace the seed read at an unfinalized start block
      Agent.update(ctx.chain, &%{&1 | finalized_answers: [@start - 1]})

      log =
        capture_log(fn ->
          assert {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 2)
          assert BatcherTimeline.address_at(timeline, 130) == @a
        end)

      assert log =~ "##{@start} is not finalized"
    end

    test "a failed history request is an error rather than an empty history", ctx do
      put_updates(ctx, [{120, @c}])
      Agent.update(ctx.chain, &%{&1 | failing: ["eth_getLogs"]})

      assert {:error, _} = BatcherTimeline.init(@contract, @start, @a, 10, ctx.rpc, retries: 1)
    end

    test "an update missing from the range logs is an error when the finalized state disagrees",
         ctx do
      put_updates(ctx, [{120, @c}])
      Agent.update(ctx.chain, &%{&1 | range_hidden: [120]})

      assert {:error, _} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)
    end

    test "a range window served by a node without the window's last block is an error", ctx do
      # without historical state, and with the finalized state agreeing with the later rotation,
      # only the window check can see the gap
      put_updates(ctx, [{110, @b}, {120, @c}])
      Agent.update(ctx.chain, &%{&1 | lagging_windows: %{110 => 109}, state_from: 125})

      assert {:error, _} = BatcherTimeline.init(@contract, @start, @a, 10, ctx.rpc, retries: 1)
    end

    test "an earlier update missing from the range logs is an error when historical state is readable",
         ctx do
      # the node has the whole window, and the finalized state agrees with the later rotation
      put_updates(ctx, [{110, @b}, {120, @c}])
      Agent.update(ctx.chain, &%{&1 | range_hidden: [110]})

      assert {:error, _} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)
    end

    test "a null answer for the finalized block is retried", ctx do
      Agent.update(ctx.chain, &%{&1 | finalized_answers: [nil]})

      assert {:ok, timeline} =
               BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 2)

      assert BatcherTimeline.address_at(timeline, 130) == @a
    end

    test "a restart reads the history from the block it resumes from", ctx do
      # the rotation at the resume block applies to it
      put_updates(ctx, [{110, @b}, {125, @c}])

      assert {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 125, retries: 1)

      assert first_ranged_log_block() == 125
      assert BatcherTimeline.address_at(timeline, 125) == @c
      assert BatcherTimeline.address_at(timeline, 130) == @c
    end

    test "the configured submitter, the batcher at the start block, is not compared with a later seed", ctx do
      put_updates(ctx, [{110, @b}])

      {result, log} =
        with_log(fn -> BatcherTimeline.init(@contract, @start, @a, 10, ctx.rpc, from: 125, retries: 1) end)

      assert {:ok, timeline} = result
      assert BatcherTimeline.address_at(timeline, 125) == @b
      refute log =~ "INDEXER_OPTIMISM_L1_BATCH_SUBMITTER"
    end

    test "a resume block before the start block reads the history from the start block", ctx do
      assert {:ok, _} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: @start - 10, retries: 1)
      assert first_ranged_log_block() == @start
    end

    test "without historical state, the finalized batcher seeds a resumed history without updates", ctx do
      put_updates(ctx, [{110, @b}])
      Agent.update(ctx.chain, &%{&1 | state_from: 129})

      assert {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 120, retries: 1)

      assert first_ranged_log_block() == 120
      assert BatcherTimeline.address_at(timeline, 120) == @b
    end

    test "reads the whole history when the batcher at the resume block is unknown", ctx do
      # the configured submitter is the batcher at the start block, not at the resume block
      put_updates(ctx, [{110, @b}, {125, @c}])
      Agent.update(ctx.chain, &%{&1 | state_from: 129})

      {result, log} =
        with_log(fn -> BatcherTimeline.init(@contract, @start, @a, 10, ctx.rpc, from: 120, retries: 1) end)

      assert {:ok, timeline} = result
      assert log =~ "read from the start block ##{@start}"
      assert first_ranged_log_block() == @start
      assert BatcherTimeline.address_at(timeline, 115) == @b
      assert BatcherTimeline.address_at(timeline, 125) == @c
    end

    test "a resume block above the finalized block reads the history from the finalized block", ctx do
      assert {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 135, retries: 1)

      assert first_ranged_log_block() == 130
      assert BatcherTimeline.address_at(timeline, 130) == @a
    end
  end

  describe "address_at/2" do
    test "refuses blocks the history does not cover yet", ctx do
      timeline = init!(ctx)

      assert_raise FunctionClauseError, fn -> BatcherTimeline.address_at(timeline, 131) end
    end

    test "authorizes nobody before the start block", ctx do
      assert ctx |> init!() |> BatcherTimeline.address_at(@start - 1) == nil
    end

    test "refuses blocks before the part of the history read on a restart", ctx do
      {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 125, retries: 1)

      assert_raise FunctionClauseError, fn -> BatcherTimeline.address_at(timeline, 124) end
    end
  end

  describe "sync/3" do
    test "reads the older history for blocks below the part read before", ctx do
      # e.g. an operator requeues old blocks for a blob retry
      put_updates(ctx, [{110, @b}, {127, @c}])
      {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 125, retries: 1)
      flush_rpc()

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 105..108), ctx.rpc)

      assert first_ranged_log_block() == 105
      assert BatcherTimeline.address_at(timeline, 105) == @a
      assert BatcherTimeline.address_at(timeline, 110) == @b
      assert BatcherTimeline.address_at(timeline, 130) == @c
    end

    test "the older history without updates needs no historical state", ctx do
      put_updates(ctx, [{110, @b}])
      Agent.update(ctx.chain, &%{&1 | state_from: 129})
      {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 125, retries: 1)
      flush_rpc()

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 115..118), ctx.rpc)

      assert first_ranged_log_block() == 115
      assert BatcherTimeline.address_at(timeline, 115) == @b
    end

    test "an update at the first block read before does not seed the older history", ctx do
      put_updates(ctx, [{110, @b}, {125, @c}])
      {:ok, timeline} = BatcherTimeline.init(@contract, @start, @a, 10, ctx.rpc, from: 125, retries: 1)
      # the node has pruned the state of the older blocks since then
      Agent.update(ctx.chain, &%{&1 | state_from: 129})

      {result, log} = with_log(fn -> BatcherTimeline.sync(timeline, blocks(ctx, 120..123), ctx.rpc) end)

      assert {:ok, timeline} = result
      assert log =~ "read from the start block ##{@start}"
      assert BatcherTimeline.address_at(timeline, 105) == @a
      assert BatcherTimeline.address_at(timeline, 120) == @b
      assert BatcherTimeline.address_at(timeline, 125) == @c
    end

    test "an older history that does not lead to the batcher at the first block read before is an error", ctx do
      put_updates(ctx, [{110, @b}])
      {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 125, retries: 1)
      # the node serving the older range misses the rotation
      Agent.update(ctx.chain, &%{&1 | range_hidden: [110]})

      assert {:error, message} = BatcherTimeline.sync(timeline, blocks(ctx, 105..108), ctx.rpc)
      assert message =~ "look incomplete"
    end

    test "blocks before the start block need no history", ctx do
      timeline = init!(ctx)
      flush_rpc()

      assert {:ok, ^timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 97..99), ctx.rpc)
      assert first_ranged_log_block() == nil
    end

    test "reading older history again keeps the unfinalized blocks read before, so their reorg is detected",
         ctx do
      {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, from: 125, retries: 1)
      {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 131..136), ctx.rpc)
      # nobody reports the fork replacing the blocks from 134, and a blob retry goes back to 105
      Agent.update(ctx.chain, &%{&1 | fork_from: 134, fork: 1})

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 105..108), ctx.rpc)
      assert {:ok, _} = BatcherTimeline.sync(timeline, blocks(ctx, 131..133), ctx.rpc)
      assert {:reorg, 131} = BatcherTimeline.sync(timeline, blocks(ctx, 134..137), ctx.rpc)
    end

    test "blocks covered by the finalized history need no requests", ctx do
      timeline = init!(ctx)
      flush_rpc()

      assert {:ok, ^timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 127..130), ctx.rpc)
      refute_received {:rpc, _}
    end

    test "updates above the finalized block are read for the processed blocks", ctx do
      timeline = init!(ctx)
      put_updates(ctx, [{132, @b}])

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 131..134), ctx.rpc)
      assert Enum.map(131..134, &BatcherTimeline.address_at(timeline, &1)) == [@a, @b, @b, @b]
    end

    test "an update of a replaced block at the same height is not applied", ctx do
      timeline = init!(ctx)

      # the node still returns the replaced block's log by number; the processed blocks belong to fork 1
      Agent.update(ctx.chain, &%{&1 | logs: [log(132, @b, fork: 0)], fork_from: 131, fork: 1})

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 131..134), ctx.rpc)
      assert BatcherTimeline.address_at(timeline, 134) == @a
    end

    test "a processed block unknown to the node fails the sync instead of skipping its updates",
         ctx do
      timeline = init!(ctx)
      put_updates(ctx, [{133, @b}])
      Agent.update(ctx.chain, &%{&1 | unavailable: [block_hash(133, 0)]})

      assert {:error, _} = BatcherTimeline.sync(timeline, blocks(ctx, 131..134), ctx.rpc)
    end

    test "blocks between the history and the chunk are read too", ctx do
      timeline = init!(ctx)
      put_updates(ctx, [{133, @b}])

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 135..138), ctx.rpc)
      assert BatcherTimeline.address_at(timeline, 135) == @b
    end

    test "a chunk that does not extend the processed blocks is a reorg from the first unfinalized block",
         ctx do
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..134), ctx.rpc)
      Agent.update(ctx.chain, &%{&1 | fork_from: 133, fork: 1})

      assert {:reorg, 131} = BatcherTimeline.sync(timeline, blocks(ctx, 135..138), ctx.rpc)
    end

    test "processed unfinalized blocks of a replaced fork are a reorg from the first unfinalized block",
         ctx do
      put_updates(ctx, [{135, @b}])
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..138), ctx.rpc)
      # the replacing fork has no rotation, and the blocks are processed again (e.g. a blob retry)
      Agent.update(ctx.chain, &%{&1 | fork_from: 135, fork: 1, logs: []})

      assert {:reorg, 131} = BatcherTimeline.sync(timeline, blocks(ctx, 135..138), ctx.rpc)
    end

    test "a chunk overlapping the processed blocks is linked at its first new block", ctx do
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..134), ctx.rpc)
      put_updates(ctx, [{136, @c}])

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 133..136), ctx.rpc)
      assert BatcherTimeline.address_at(timeline, 135) == @a
      assert BatcherTimeline.address_at(timeline, 136) == @c
    end

    test "a finalized block that differs from the processed one is a reorg from the first unfinalized block",
         ctx do
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..134), ctx.rpc)
      # 131..134 were replaced without any reorg report, and the replacement is finalized
      Agent.update(ctx.chain, &%{&1 | fork_from: 131, fork: 1, finalized: 134})

      assert {:reorg, 131} = BatcherTimeline.sync(timeline, blocks(ctx, 135..136), ctx.rpc)
    end

    test "a processed block becomes final only by the answer of the node that reports finality",
         ctx do
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..134), ctx.rpc)
      chunk = blocks(ctx, 135..136)

      # a fork replacing 131.. is finalized up to 140, while another node still returns the old block 134
      Agent.update(ctx.chain, fn chain ->
        %{
          chain
          | fork_from: 131,
            fork: 1,
            head: 150,
            finalized: 140,
            stale_headers: [134],
            known_orphans: true
        }
      end)

      assert {:reorg, 131} = BatcherTimeline.sync(timeline, chunk, ctx.rpc)
    end

    test "updates read by block hash stay when their blocks become finalized, whatever the range view",
         ctx do
      put_updates(ctx, [{132, @b}])
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..134), ctx.rpc)
      Agent.update(ctx.chain, &%{&1 | finalized: 134, range_hidden: [132]})

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 135..136), ctx.rpc)
      assert timeline |> BatcherTimeline.truncate(130) |> BatcherTimeline.address_at(134) == @b
    end

    test "blocks finalized beyond the history are read by hash and become finalized when processed",
         ctx do
      timeline = init!(ctx)
      put_updates(ctx, [{140, @b}])
      Agent.update(ctx.chain, &%{&1 | head: 160, finalized: 150, range_hidden: [140]})

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 151..152), ctx.rpc)
      assert BatcherTimeline.address_at(timeline, 139) == @a
      assert BatcherTimeline.address_at(timeline, 140) == @b

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 153..154), ctx.rpc)
      assert timeline |> BatcherTimeline.truncate(130) |> BatcherTimeline.address_at(150) == @b
    end

    test "a chunk uses the updates of its own blocks even when another fork is finalized meanwhile",
         ctx do
      timeline = init!(ctx)
      put_updates(ctx, [{132, @b}])
      chunk = blocks(ctx, 131..134)

      # before the sync, a fork rotating at 133 replaces the chunk blocks and becomes finalized
      Agent.update(ctx.chain, fn chain ->
        %{
          chain
          | fork_from: 131,
            fork: 1,
            finalized: 134,
            logs: chain.logs ++ [log(133, @b, fork: 1)],
            batcher: [{0, @a}, {133, @b}],
            range_canonical_only: true,
            known_orphans: true
        }
      end)

      assert {:ok, timeline} = BatcherTimeline.sync(timeline, chunk, ctx.rpc)
      assert BatcherTimeline.address_at(timeline, 132) == @b
    end
  end

  describe "truncate/2" do
    test "makes the next sync read the blocks above the given one from the new fork", ctx do
      put_updates(ctx, [{132, @b}])
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..134), ctx.rpc)
      # the replacing fork has the rotation at 133 instead of 132
      Agent.update(ctx.chain, &%{&1 | fork_from: 132, fork: 1, logs: [log(133, @b, fork: 1)]})

      assert {:ok, timeline} =
               timeline
               |> BatcherTimeline.truncate(131)
               |> BatcherTimeline.sync(blocks(ctx, 132..134), ctx.rpc)

      assert BatcherTimeline.address_at(timeline, 132) == @a
      assert BatcherTimeline.address_at(timeline, 133) == @b
    end

    test "keeps the hashes up to the given block, so the next sync detects a reorg that started below it",
         ctx do
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..136), ctx.rpc)
      # the fork replaces the blocks from 134, but the reorg is reported at 136
      Agent.update(ctx.chain, &%{&1 | fork_from: 134, fork: 1})

      assert {:reorg, 131} =
               timeline
               |> BatcherTimeline.truncate(135)
               |> BatcherTimeline.sync(blocks(ctx, 136..137), ctx.rpc)
    end

    test "keeps the updates that became finalized", ctx do
      put_updates(ctx, [{133, @b}])
      {:ok, timeline} = BatcherTimeline.sync(init!(ctx), blocks(ctx, 131..138), ctx.rpc)
      Agent.update(ctx.chain, &%{&1 | finalized: 136})
      {:ok, timeline} = BatcherTimeline.sync(timeline, blocks(ctx, 139..140), ctx.rpc)

      assert timeline |> BatcherTimeline.truncate(131) |> BatcherTimeline.address_at(136) == @b
    end
  end

  defp init!(ctx) do
    {:ok, timeline} = BatcherTimeline.init(@contract, @start, nil, 10, ctx.rpc, retries: 1)
    timeline
  end

  defp put_updates(ctx, updates) do
    Agent.update(ctx.chain, fn chain ->
      %{
        chain
        | logs: chain.logs ++ Enum.map(updates, fn {block, address} -> log(block, address) end),
          batcher: chain.batcher ++ updates
      }
    end)
  end

  defp flush_rpc do
    receive do
      {:rpc, _} -> flush_rpc()
    after
      0 -> :ok
    end
  end

  # The lowest block of the ranged eth_getLogs requests sent so far (nil without any).
  defp first_ranged_log_block(lowest \\ nil) do
    receive do
      {:rpc, request} ->
        request
        |> List.wrap()
        |> Enum.flat_map(fn
          %{method: "eth_getLogs", params: [%{fromBlock: from}]} -> [quantity_to_integer(from)]
          _ -> []
        end)
        |> Enum.concat(List.wrap(lowest))
        |> Enum.min(fn -> nil end)
        |> first_ranged_log_block()
    after
      0 -> lowest
    end
  end

  defp blocks(ctx, range) do
    chain = Agent.get(ctx.chain, & &1)

    Enum.map(range, fn n ->
      %{number: n, hash: canonical_hash(chain, n), parent_hash: canonical_hash(chain, n - 1)}
    end)
  end

  defp respond(requests, chain) when is_list(requests) do
    finality? = Enum.any?(requests, &match?(%{params: ["finalized", _]}, &1))
    chain = requests |> lagging_view(chain) |> Map.put(:stale_view, not finality?)

    {:ok,
     Enum.map(requests, fn %{id: id} = request ->
       case respond(request, chain) do
         {:ok, result} -> %{id: id, result: result}
         {:error, error} -> %{id: id, error: error}
       end
     end)}
  end

  defp respond(%{method: method} = request, chain) do
    if method in chain.failing do
      {:error, %{code: -32_000, message: "request failed"}}
    else
      respond_to(request, chain)
    end
  end

  defp lagging_view(requests, chain) do
    Enum.reduce(requests, chain, fn
      %{method: "eth_getLogs", params: [%{fromBlock: from}]}, acc ->
        case Map.fetch(chain.lagging_windows, quantity_to_integer(from)) do
          {:ok, head} -> %{acc | head: head}
          :error -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp respond_to(%{method: "eth_getBlockByNumber", params: ["finalized", false]}, chain),
    do: {:ok, header(chain, chain.finalized)}

  defp respond_to(%{method: "eth_getBlockByNumber", params: [number, false]}, chain) do
    number = quantity_to_integer(number)

    cond do
      number > chain.head ->
        {:ok, nil}

      Map.get(chain, :stale_view, false) and number in chain.stale_headers ->
        {:ok, header(%{chain | fork_from: nil}, number)}

      true ->
        {:ok, header(chain, number)}
    end
  end

  defp respond_to(%{method: "eth_getLogs", params: [%{blockHash: hash}]}, chain) do
    if hash in chain.unavailable or not known_hash?(chain, hash) do
      {:error, %{code: -32_000, message: "unknown block"}}
    else
      {:ok, for(log <- chain.logs, block_hash(log.block, log.fork) == hash, do: rpc_log(log))}
    end
  end

  defp respond_to(%{method: "eth_getLogs", params: [%{fromBlock: from, toBlock: to}]}, chain) do
    range = quantity_to_integer(from)..quantity_to_integer(to)

    {:ok,
     for(
       log <- chain.logs,
       log.block in range,
       log.block <= chain.head,
       log.block not in chain.range_hidden,
       not chain.range_canonical_only or
         block_hash(log.block, log.fork) == canonical_hash(chain, log.block),
       do: rpc_log(log)
     )}
  end

  defp respond_to(%{method: "eth_call", params: [%{data: "0xe81b2c6d"}, block]}, chain) do
    number =
      case block do
        %{blockHash: hash} -> canonical_number(chain, hash)
        quantity -> quantity_to_integer(quantity)
      end

    if is_nil(number) or number < chain.state_from or number in chain.unreadable do
      {:error, %{code: -32_000, message: "missing trie node"}}
    else
      {_, address} =
        chain.batcher
        |> Enum.filter(fn {from, _} -> from <= number end)
        |> Enum.max_by(&elem(&1, 0))

      {:ok, encode(<<0::96>> <> decode(address))}
    end
  end

  defp header(chain, number) do
    %{
      "number" => quantity(number),
      "hash" => canonical_hash(chain, number),
      "parentHash" => canonical_hash(chain, number - 1),
      "timestamp" => quantity(1_700_000_000 + number * 12)
    }
  end

  defp canonical_number(chain, hash),
    do: Enum.find(0..chain.head, &(canonical_hash(chain, &1) == hash))

  defp known_hash?(chain, hash) do
    not is_nil(canonical_number(chain, hash)) or
      (chain.known_orphans and
         Enum.any?(0..chain.head, fn n ->
           Enum.any?(0..chain.fork, &(block_hash(n, &1) == hash))
         end))
  end

  defp canonical_hash(%{fork_from: from, fork: fork}, number)
       when is_integer(from) and number >= from,
       do: block_hash(number, fork)

  defp canonical_hash(_chain, number), do: block_hash(number, 0)

  defp block_hash(number, fork), do: encode(<<number + fork * 1_000_000::256>>)

  defp log(block, batcher, opts \\ []) do
    %{
      block: block,
      index: Keyword.get(opts, :index, 0),
      fork: Keyword.get(opts, :fork, 0),
      address: Keyword.get(opts, :address, @contract),
      topics: Keyword.get(opts, :topics, [@event, @zero_topic, @zero_topic]),
      data: Keyword.get(opts, :data, encode(<<32::256, 32::256, 0::96>> <> decode(batcher))),
      removed: Keyword.get(opts, :removed, false)
    }
  end

  defp rpc_log(log) do
    %{
      "address" => log.address,
      "blockHash" => block_hash(log.block, log.fork),
      "blockNumber" => quantity(log.block),
      "data" => log.data,
      "logIndex" => quantity(log.index),
      "removed" => log.removed,
      "topics" => log.topics,
      "transactionHash" => encode(<<log.block::128, log.index::128>>),
      "transactionIndex" => "0x0"
    }
  end

  defp quantity(number), do: EthereumJSONRPC.integer_to_quantity(number)
  defp quantity_to_integer(quantity), do: EthereumJSONRPC.quantity_to_integer(quantity)
  defp encode(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp decode("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
end
