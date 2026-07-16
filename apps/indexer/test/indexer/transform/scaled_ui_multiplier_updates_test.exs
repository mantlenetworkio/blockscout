defmodule Indexer.Transform.ScaledUiMultiplierUpdatesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Explorer.Chain.ScaledUi.Events
  alias Indexer.Transform.ScaledUiMultiplierUpdates

  describe "parse/2" do
    test "parses the Mantle Hoodi pending overwrite receipt in emitted order" do
      token = "0xe916f4d7a32054ea2fbcf06ba52a6b864776b4f4"
      transaction_hash = "0x702468a5bfcddc65a03b603734d67137064d1ef752fb567caaa48429c9c6deb1"
      block_number = 0x2064BE
      block_timestamp = DateTime.from_unix!(0x6A588754)

      overwritten = %{
        log(
          Events.ui_multiplier_change_overwritten_topic(),
          block_number,
          0,
          "0x00000000000000000000000000000000000000000000000029a2241af62c0000" <>
            "000000000000000000000000000000000000000000000000000000006a80144a" <>
            "00000000000000000000000000000000000000000000000022b1c8c1227a0000" <>
            "000000000000000000000000000000000000000000000000000000006aa7a14a",
          token
        )
        | block_hash: "0xd7d98a5916a99d0b154a898696366d5aac9572927689db9b55498a4ba582ee37",
          transaction_hash: transaction_hash
      }

      updated = %{
        log(
          Events.ui_multiplier_updated_topic(),
          block_number,
          1,
          "0x0000000000000000000000000000000000000000000000001bc16d674ec80000" <>
            "00000000000000000000000000000000000000000000000022b1c8c1227a0000" <>
            "000000000000000000000000000000000000000000000000000000006aa7a14a",
          token
        )
        | block_hash: "0xd7d98a5916a99d0b154a898696366d5aac9572927689db9b55498a4ba582ee37",
          transaction_hash: transaction_hash
      }

      assert [parsed_overwritten, parsed_updated] =
               ScaledUiMultiplierUpdates.parse(
                 [overwritten, updated],
                 %{block_number => block_timestamp}
               )

      assert parsed_overwritten.event_type == "overwritten"
      assert Decimal.equal?(parsed_overwritten.overwritten_multiplier, Decimal.new("3000000000000000000"))
      assert Decimal.equal?(parsed_overwritten.new_multiplier, Decimal.new("2500000000000000000"))
      assert Decimal.equal?(parsed_overwritten.effective_at, Decimal.new(1_789_370_698))
      assert parsed_updated.event_type == "updated"
      assert Decimal.equal?(parsed_updated.old_multiplier, Decimal.new("2000000000000000000"))
      assert Decimal.equal?(parsed_updated.new_multiplier, Decimal.new("2500000000000000000"))
    end

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
