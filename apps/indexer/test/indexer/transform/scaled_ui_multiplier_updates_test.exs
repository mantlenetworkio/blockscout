defmodule Indexer.Transform.ScaledUiMultiplierUpdatesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Explorer.Chain.ScaledUi.Events
  alias Indexer.Transform.ScaledUiMultiplierUpdates

  describe "parse/2" do
    test "parses updated and overwritten events with block timestamps" do
      updated_log =
        log(
          Events.ui_multiplier_updated_topic(),
          100,
          3,
          encode_uints([0, 1_000_000_000_000_000_000, 1_750_000_100])
        )

      overwritten_log =
        log(
          Events.ui_multiplier_change_overwritten_topic(),
          101,
          7,
          encode_uints([
            2_000_000_000_000_000_000,
            1_750_000_200,
            3_000_000_000_000_000_000,
            1_750_000_300
          ])
        )

      block_timestamps = %{
        100 => DateTime.from_unix!(1_750_000_000),
        101 => DateTime.from_unix!(1_750_000_050)
      }

      assert [updated, overwritten] =
               ScaledUiMultiplierUpdates.parse([updated_log, overwritten_log], block_timestamps)

      assert updated == %{
               token_contract_address_hash: updated_log.address_hash,
               transaction_hash: updated_log.transaction_hash,
               block_hash: updated_log.block_hash,
               log_index: 3,
               block_number: 100,
               block_timestamp: Decimal.new(1_750_000_000),
               event_type: "updated",
               old_multiplier: Decimal.new(0),
               new_multiplier: Decimal.new(1_000_000_000_000_000_000),
               effective_at: Decimal.new(1_750_000_100),
               overwritten_multiplier: nil,
               overwritten_effective_at: nil
             }

      assert overwritten == %{
               token_contract_address_hash: overwritten_log.address_hash,
               transaction_hash: overwritten_log.transaction_hash,
               block_hash: overwritten_log.block_hash,
               log_index: 7,
               block_number: 101,
               block_timestamp: Decimal.new(1_750_000_050),
               event_type: "overwritten",
               old_multiplier: nil,
               new_multiplier: Decimal.new(3_000_000_000_000_000_000),
               effective_at: Decimal.new(1_750_000_300),
               overwritten_multiplier: Decimal.new(2_000_000_000_000_000_000),
               overwritten_effective_at: Decimal.new(1_750_000_200)
             }
    end

    test "skips malformed event data without failing the batch" do
      malformed_log = log(Events.ui_multiplier_updated_topic(), 100, 3, encode_uints([1]))

      warning =
        capture_log(fn ->
          assert ScaledUiMultiplierUpdates.parse(
                   [malformed_log],
                   %{100 => DateTime.from_unix!(1_750_000_000)}
                 ) == []
        end)

      assert warning =~ "Skipping malformed ERC-8056 multiplier event"
    end
  end

  describe "capability_rows/1" do
    test "keeps the earliest block for each token across all ERC-8056 topics" do
      token_a = "0x00000000000000000000000000000000000000aa"
      token_b = "0x00000000000000000000000000000000000000bb"

      logs = [
        log(Events.ui_multiplier_updated_topic(), 14, 1, encode_uints([0, 1, 1]), token_a),
        log(Events.transfer_with_ui_amount_topic(), 12, 2, "0x", token_a),
        log(Events.ui_multiplier_change_overwritten_topic(), 20, 3, encode_uints([1, 1, 2, 2]), token_b),
        log("0x" <> String.duplicate("ff", 32), 1, 4, "0x", token_b)
      ]

      assert ScaledUiMultiplierUpdates.capability_rows(logs) == [
               %{token_contract_address_hash: token_a, capability_block: 12},
               %{token_contract_address_hash: token_b, capability_block: 20}
             ]
    end
  end

  defp log(topic, block_number, index, data, address_hash \\ "0x0000000000000000000000000000000000000001") do
    %{
      address_hash: address_hash,
      block_number: block_number,
      block_hash: "0x" <> String.pad_leading(Integer.to_string(block_number, 16), 64, "0"),
      data: data,
      first_topic: topic,
      index: index,
      transaction_hash: "0x" <> String.pad_leading(Integer.to_string(index, 16), 64, "0")
    }
  end

  defp encode_uints(values) do
    types = Enum.map(values, fn _ -> {:uint, 256} end)
    "0x" <> Base.encode16(ABI.TypeEncoder.encode(values, types), case: :lower)
  end
end
