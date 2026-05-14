defmodule Indexer.Fetcher.RollupL1ReorgMonitorTest do
  use ExUnit.Case, async: true

  alias Indexer.Fetcher.RollupL1ReorgMonitor

  describe "reorg_block_to_enqueue/3" do
    test "detects a same-height reorg when the previous latest block hash changes" do
      previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}
      current_latest = %{number: 2_800_660, hash: "0xbeef"}
      current_previous_latest = %{number: 2_800_657, hash: "0x7ca9eb29"}

      assert RollupL1ReorgMonitor.reorg_block_to_enqueue(
               previous_latest,
               current_latest,
               current_previous_latest
             ) == 2_800_657
    end

    test "detects a height rollback" do
      previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}
      current_latest = %{number: 2_800_656, hash: "0x7ca9eb29"}

      assert RollupL1ReorgMonitor.reorg_block_to_enqueue(previous_latest, current_latest, nil) == 2_800_656
    end

    test "ignores unchanged canonical previous latest block" do
      previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}
      current_latest = %{number: 2_800_660, hash: "0xbeef"}
      current_previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}

      assert is_nil(
               RollupL1ReorgMonitor.reorg_block_to_enqueue(
                 previous_latest,
                 current_latest,
                 current_previous_latest
               )
             )
    end

    test "ignores first tick when no previous snapshot is available" do
      # First tick after pod start: prev_latest = 0, prev_latest_hash = nil,
      # and fetch_current_previous_latest_block returns nil for prev_latest == 0.
      previous_latest = %{number: 0, hash: nil}
      current_latest = %{number: 2_800_657, hash: "0xc52ab1be"}

      assert is_nil(RollupL1ReorgMonitor.reorg_block_to_enqueue(previous_latest, current_latest, nil))
    end

    test "ignores tick when re-fetching previous-latest height fails" do
      # We had a snapshot, but this tick's RPC call to re-fetch the canonical
      # block at prev_latest height failed (current_previous_latest = nil).
      # Don't false-positive — try again on the next tick.
      previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}
      current_latest = %{number: 2_800_660, hash: "0xbeef"}

      assert is_nil(RollupL1ReorgMonitor.reorg_block_to_enqueue(previous_latest, current_latest, nil))
    end

    test "compares hashes case-insensitively (no false positive on mixed case)" do
      previous_latest = %{number: 2_800_657, hash: "0xC52AB1BE"}
      current_latest = %{number: 2_800_660, hash: "0xbeef"}
      current_previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}

      assert is_nil(
               RollupL1ReorgMonitor.reorg_block_to_enqueue(
                 previous_latest,
                 current_latest,
                 current_previous_latest
               )
             )
    end

    test "prefers height-rollback signal over same-height hash comparison" do
      # Even when the previous-latest height happens to still report the same hash,
      # a strictly decreasing `latest` is the unambiguous rollback signal and must win.
      previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}
      current_latest = %{number: 2_800_656, hash: "0x7ca9eb29"}
      current_previous_latest = %{number: 2_800_657, hash: "0xc52ab1be"}

      assert RollupL1ReorgMonitor.reorg_block_to_enqueue(
               previous_latest,
               current_latest,
               current_previous_latest
             ) == 2_800_656
    end
  end
end
