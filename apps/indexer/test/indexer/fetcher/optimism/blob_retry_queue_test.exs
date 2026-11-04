# SPDX-License-Identifier: LicenseRef-Blockscout
if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Fetcher.Optimism.BlobRetryQueueTest do
    use Explorer.DataCase, async: false

    import ExUnit.CaptureLog, only: [capture_log: 1]

    alias Ecto.Adapters.SQL.Sandbox
    alias Explorer.Chain.Cache.Counters.LastFetchedCounter
    alias Indexer.Fetcher.Optimism.BlobRetryQueue

    @counter_type "optimism_blob_retry_queue_min_l1_block"

    describe "the lowest queued block" do
      test "is kept from when it is queued until a rescan has imported its blocks" do
        start_supervised!(BlobRetryQueue)

        BlobRetryQueue.enqueue(120, "0x01", "0xa1")
        assert stored_block() == 120

        BlobRetryQueue.enqueue(110, "0x02", "0xa2")
        assert stored_block() == 110

        # the batches of the recovered blob are not imported yet
        BlobRetryQueue.mark_blob_succeeded(110, "0x02")
        assert stored_block() == 110

        # the chunk of block 110 is imported
        BlobRetryQueue.mark_range_imported(105, 115)
        assert stored_block() == 120

        BlobRetryQueue.clear()
        assert stored_block() == nil
      end

      test "does not move above a recovered block when the rescan queues a later one" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.enqueue(110, "0x02", "0xa2")

        # the rescan recovers the blob of block 110, and finds one of block 112 missing, before importing them
        BlobRetryQueue.mark_blob_succeeded(110, "0x02")
        BlobRetryQueue.enqueue(112, "0x05", "0xa5")
        assert stored_block() == 110

        BlobRetryQueue.mark_range_imported(110, 115)
        assert stored_block() == 112
      end

      # The batch fetcher's checkpoint has moved past the queued blocks: only the queue brings them back. Due like a
      # newly queued block, it does not make a restart during a catch-up scan from it before the catch-up goes on.
      test "is rescanned after a restart, once due like a newly queued block" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.enqueue(120, "0x01", "0xa1")
        BlobRetryQueue.enqueue(110, "0x02", "0xa2")

        stop_supervised!(BlobRetryQueue)
        start_supervised!(BlobRetryQueue)
        # as the batch fetcher does when it starts
        BlobRetryQueue.restore()
        assert BlobRetryQueue.due_min_block() == nil

        # its first backoff has passed
        Agent.update(BlobRetryQueue, &put_in(&1, [110, :last_attempt_at], 0))

        # the rescan from block 110 covers block 120 as well
        assert BlobRetryQueue.due_min_block() == 110
        assert BlobRetryQueue.size() == 1
      end

      test "does not replace the entries of a queue that outlived a restart of the batch fetcher" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.enqueue(110, "0x02", "0xa2")
        BlobRetryQueue.mark_range_attempted(110, 110)

        BlobRetryQueue.restore()

        assert %{110 => %{attempts: 1, blob_hashes: blob_hashes}} = BlobRetryQueue.snapshot()
        assert MapSet.to_list(blob_hashes) == ["0x02"]
      end

      test "fails the enqueue that lowers it when it cannot be kept, and leaves the queue as it was" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.enqueue(120, "0x01", "0xa1")
        # the queue loses the DB, which it reached through the shared sandbox connection
        Sandbox.mode(Explorer.Repo, :manual)

        capture_log(fn ->
          assert_raise RuntimeError, fn -> BlobRetryQueue.enqueue(110, "0x02", "0xa2") end
        end)

        assert Map.keys(BlobRetryQueue.snapshot()) == [120]

        # the rescan from block 120 covers a later block, which needs no write
        BlobRetryQueue.enqueue(130, "0x03", "0xa3")
        assert Map.keys(BlobRetryQueue.snapshot()) == [120, 130]
      end
    end

    describe "a block queued only to be rescanned" do
      # a restart in the middle of a long rescan must not take it up from the block again
      test "leaves the queue once its chunk is imported, while a blob still missing stays queued" do
        LastFetchedCounter.upsert(%{counter_type: @counter_type, value: 110})
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.restore()
        BlobRetryQueue.requeue_for_rescan(140)

        # the rescan from block 110 finds a blob of block 115 still missing
        BlobRetryQueue.enqueue(115, "0x03", "0xa3")
        BlobRetryQueue.mark_range_imported(110, 130)

        assert Map.keys(BlobRetryQueue.snapshot()) == [115, 140]
        assert stored_block() == 115
      end

      # the frames of an incomplete channel are kept in memory only
      test "stays queued while it carries frames of a channel still incomplete" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.requeue_for_rescan(110)

        BlobRetryQueue.mark_range_imported(100, 120, MapSet.new([110]))

        assert Map.keys(BlobRetryQueue.snapshot()) == [110]
      end

      test "stays queued when an L1 reorg halts its rescan before its chunk is imported" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.requeue_for_rescan(110)

        BlobRetryQueue.mark_range_attempted(110, 110)

        assert %{110 => %{attempts: 1}} = BlobRetryQueue.snapshot()
      end

      test "stays queued when its own blob is still missing" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.requeue_for_rescan(110)

        # the rescan finds the blob of block 110 missing again
        BlobRetryQueue.enqueue(110, "0x04", "0xa4")
        BlobRetryQueue.mark_range_imported(110, 110)

        assert Map.keys(BlobRetryQueue.snapshot()) == [110]
        assert BlobRetryQueue.missing_below?(111)
      end

      test "is only the lowest block of a range: the rescan from it covers the others" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.requeue_for_rescan(130..100//-1)
        BlobRetryQueue.requeue_for_rescan([150, 140])

        assert Map.keys(BlobRetryQueue.snapshot()) == [100, 140]
      end
    end

    # the batch fetcher does not wait for a blob of a block that a rescan covers anyway
    describe "missing_below?/1" do
      # the rescan of block 110 tries its blob again: waiting for it can save the next rescan from the block
      test "is true above a block queued with a missing blob, not at it, nor above a block queued only to be rescanned" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.requeue_for_rescan(100)
        BlobRetryQueue.enqueue(110, "0x02", "0xa2")

        refute BlobRetryQueue.missing_below?(110)
        assert BlobRetryQueue.missing_below?(111)
      end

      test "is false once the missing blob of the block is recovered" do
        start_supervised!(BlobRetryQueue)
        BlobRetryQueue.enqueue(110, "0x02", "0xa2")
        BlobRetryQueue.mark_blob_succeeded(110, "0x02")

        refute BlobRetryQueue.missing_below?(120)
      end
    end

    defp stored_block do
      case LastFetchedCounter.get(@counter_type, nullable: true) do
        nil -> nil
        value -> Decimal.to_integer(value)
      end
    end
  end
end
