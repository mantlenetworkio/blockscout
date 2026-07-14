defmodule Explorer.Chain.ScaledUi.TimelineTest do
  use ExUnit.Case, async: true

  alias Explorer.Chain.ScaledUi.Timeline

  describe "replay/1" do
    test "initializes from old zero and applies an immediate multiplier" do
      summary = Timeline.replay([updated(1, 1, 100, 0, 1_000, 100)])

      assert_decimal(summary.base_multiplier, 1_000)
      assert summary.pending_multiplier == nil
      assert summary.pending_effective_at == nil
      assert summary.timeline_status == "ok"
      assert summary.tainted_from_block == nil
    end

    test "rejects old zero after a trusted base exists" do
      summary =
        Timeline.replay([
          updated(1, 1, 100, 0, 1_000, 100),
          updated(2, 1, 200, 0, 2_000, 200)
        ])

      assert summary.timeline_status == "tainted"
      assert summary.tainted_from_block == 2
    end

    test "keeps a future multiplier pending" do
      summary =
        Timeline.replay([
          updated(1, 1, 100, 0, 1_000, 100),
          updated(2, 1, 200, 1_000, 2_000, 300)
        ])

      assert_decimal(summary.base_multiplier, 1_000)
      assert_decimal(summary.pending_multiplier, 2_000)
      assert_decimal(summary.pending_effective_at, 300)
      assert summary.timeline_status == "ok"
    end

    test "settles an expired pending multiplier before validating the next event" do
      summary =
        Timeline.replay([
          updated(1, 1, 100, 0, 1_000, 100),
          updated(2, 1, 200, 1_000, 2_000, 250),
          updated(3, 1, 300, 2_000, 3_000, 300)
        ])

      assert_decimal(summary.base_multiplier, 3_000)
      assert summary.pending_multiplier == nil
      assert summary.timeline_status == "ok"
    end

    test "accepts an adjacent updated and overwritten pair in either log order" do
      initial_events = [
        updated(1, 1, 100, 0, 1_000, 100),
        updated(2, 1, 200, 1_000, 2_000, 400)
      ]

      pairs = [
        [
          updated(3, 5, 300, 1_000, 3_000, 500, "updated-first"),
          overwritten(3, 6, 300, 2_000, 400, 3_000, 500, "updated-first")
        ],
        [
          overwritten(3, 5, 300, 2_000, 400, 3_000, 500, "overwritten-first"),
          updated(3, 6, 300, 1_000, 3_000, 500, "overwritten-first")
        ]
      ]

      for pair <- pairs do
        summary = Timeline.replay(initial_events ++ pair)

        assert_decimal(summary.base_multiplier, 1_000)
        assert_decimal(summary.pending_multiplier, 3_000)
        assert_decimal(summary.pending_effective_at, 500)
        assert summary.timeline_status == "ok"
      end
    end

    test "taints an isolated overwritten event" do
      summary =
        Timeline.replay([
          updated(1, 1, 100, 0, 1_000, 100),
          updated(2, 1, 200, 1_000, 2_000, 400),
          overwritten(3, 6, 300, 2_000, 400, 3_000, 500, "isolated")
        ])

      assert summary.timeline_status == "tainted"
      assert summary.tainted_from_block == 3
    end

    test "taints a malformed overwrite pair" do
      summary =
        Timeline.replay([
          updated(1, 1, 100, 0, 1_000, 100),
          updated(2, 1, 200, 1_000, 2_000, 400),
          updated(3, 5, 300, 1_000, 3_000, 500, "pair"),
          overwritten(3, 6, 300, 2_000, 400, 4_000, 500, "pair")
        ])

      assert summary.timeline_status == "tainted"
      assert summary.tainted_from_block == 3
    end

    test "taints an updated event whose old multiplier does not match the base" do
      summary =
        Timeline.replay([
          updated(1, 1, 100, 0, 1_000, 100),
          updated(7, 1, 200, 999, 2_000, 200)
        ])

      assert summary.timeline_status == "tainted"
      assert summary.tainted_from_block == 7
    end
  end

  describe "multiplier_at/4" do
    test "settles pending at and after its effective timestamp" do
      events = [
        updated(1, 1, 100, 0, 1_000, 100),
        updated(2, 1, 200, 1_000, 2_000, 300)
      ]

      assert_decimal(Timeline.multiplier_at(events, 3, 1, d(299)), 1_000)
      assert_decimal(Timeline.multiplier_at(events, 3, 1, d(300)), 2_000)
      assert_decimal(Timeline.multiplier_at(events, 3, 1, d(301)), 2_000)
    end

    test "uses log index granularity within a block" do
      events = [updated(5, 10, 500, 0, 2_000, 500)]

      assert Timeline.multiplier_at(events, 5, 10, d(500)) == nil
      assert_decimal(Timeline.multiplier_at(events, 5, 11, d(500)), 2_000)
    end

    test "returns nil once the replay prefix is tainted" do
      events = [
        updated(1, 1, 100, 0, 1_000, 100),
        updated(2, 1, 200, 999, 2_000, 200)
      ]

      assert Timeline.multiplier_at(events, 3, 1, d(300)) == nil
    end
  end

  describe "current_multiplier/2" do
    test "returns the base without pending state" do
      state = %{base_multiplier: d(1_000), pending_multiplier: nil, pending_effective_at: nil, timeline_status: "ok"}

      assert {:ok, multiplier} = Timeline.current_multiplier(state, d(500))
      assert_decimal(multiplier, 1_000)
    end

    test "returns pending at and after its effective timestamp" do
      state = %{
        base_multiplier: d(1_000),
        pending_multiplier: d(2_000),
        pending_effective_at: d(500),
        timeline_status: "ok"
      }

      assert {:ok, multiplier} = Timeline.current_multiplier(state, d(500))
      assert_decimal(multiplier, 2_000)
    end

    test "returns unknown for absent, unevaluated, empty, or tainted state" do
      assert Timeline.current_multiplier(nil, d(500)) == :unknown

      assert Timeline.current_multiplier(
               %{base_multiplier: d(1_000), pending_multiplier: nil, pending_effective_at: nil, timeline_status: nil},
               d(500)
             ) == :unknown

      assert Timeline.current_multiplier(
               %{base_multiplier: nil, pending_multiplier: nil, pending_effective_at: nil, timeline_status: "ok"},
               d(500)
             ) == :unknown

      assert Timeline.current_multiplier(
               %{
                 base_multiplier: d(1_000),
                 pending_multiplier: nil,
                 pending_effective_at: nil,
                 timeline_status: "tainted"
               },
               d(500)
             ) == :unknown
    end
  end

  defp updated(block, log_index, timestamp, old, new, effective_at, transaction_hash \\ "tx") do
    %{
      block_number: block,
      log_index: log_index,
      block_timestamp: d(timestamp),
      transaction_hash: transaction_hash,
      event_type: "updated",
      old_multiplier: d(old),
      new_multiplier: d(new),
      effective_at: d(effective_at)
    }
  end

  defp overwritten(block, log_index, timestamp, old_pending, old_effective_at, new, effective_at, transaction_hash) do
    %{
      block_number: block,
      log_index: log_index,
      block_timestamp: d(timestamp),
      transaction_hash: transaction_hash,
      event_type: "overwritten",
      overwritten_multiplier: d(old_pending),
      overwritten_effective_at: d(old_effective_at),
      new_multiplier: d(new),
      effective_at: d(effective_at)
    }
  end

  defp assert_decimal(actual, expected), do: assert(Decimal.equal?(actual, d(expected)))
  defp d(value), do: Decimal.new(value)
end
