defmodule Indexer.Transform.ScaledUiTokenTransfersTest do
  use Explorer.DataCase

  alias Explorer.Chain.ScaledUi.Events
  alias Explorer.Chain.TokenTransfer
  alias Indexer.Transform.TokenTransfers

  @token_a "0x1111111111111111111111111111111111111111"
  @token_b "0x2222222222222222222222222222222222222222"
  @from "0x3333333333333333333333333333333333333333"
  @to "0x4444444444444444444444444444444444444444"
  @transaction_hash "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @block_hash "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @zero "0x0000000000000000000000000000000000000000"

  describe "parse/2 ERC-8056 pairing" do
    test "parses Mantle Hoodi 2x and zero-multiplier receipts" do
      two_x_logs = [
        hoodi_transfer_log(
          "0xe916f4d7a32054ea2fbcf06ba52a6b864776b4f4",
          "0xd9849232998b908f6cccd1c12c4e039ec553181937ed4ce7fd53627d8a903356",
          "0x881df500f44db1f097281dec31c3d1badfd76f622d03cd0b336370ae859f0af7",
          0x2064B9,
          0,
          "0x0000000000000000000000002595be55daad0c73b02755539d73283e8b0d7e37",
          "0x000000000000000000000000ed3ce153d4bb5994b09595b20b2315f549081c1e",
          "0x000000000000000000000000000000000000000000000001a055690d9db80000",
          TokenTransfer.constant()
        ),
        hoodi_transfer_log(
          "0xe916f4d7a32054ea2fbcf06ba52a6b864776b4f4",
          "0xd9849232998b908f6cccd1c12c4e039ec553181937ed4ce7fd53627d8a903356",
          "0x881df500f44db1f097281dec31c3d1badfd76f622d03cd0b336370ae859f0af7",
          0x2064B9,
          1,
          "0x0000000000000000000000002595be55daad0c73b02755539d73283e8b0d7e37",
          "0x000000000000000000000000ed3ce153d4bb5994b09595b20b2315f549081c1e",
          "0x000000000000000000000000000000000000000000000001a055690d9db80000" <>
            "00000000000000000000000000000000000000000000000340aad21b3b700000",
          Events.transfer_with_ui_amount_topic()
        )
      ]

      zero_multiplier_logs = [
        hoodi_transfer_log(
          "0x8f542fd88031dc30c2014213632e4f975f34dcd9",
          "0xdd144513a75010becc3abd30fdbed860d856eebffbd69dce7fea6449f100d966",
          "0x8fcf56d20d53a6a39e7e24880242f5e2f959c542ece6187f7183e5f1bf5aa04c",
          0x2064F0,
          0,
          "0x000000000000000000000000ed3ce153d4bb5994b09595b20b2315f549081c1e",
          "0x0000000000000000000000002595be55daad0c73b02755539d73283e8b0d7e37",
          "0x0000000000000000000000000000000000000000000000008ac7230489e80000",
          TokenTransfer.constant()
        ),
        hoodi_transfer_log(
          "0x8f542fd88031dc30c2014213632e4f975f34dcd9",
          "0xdd144513a75010becc3abd30fdbed860d856eebffbd69dce7fea6449f100d966",
          "0x8fcf56d20d53a6a39e7e24880242f5e2f959c542ece6187f7183e5f1bf5aa04c",
          0x2064F0,
          1,
          "0x000000000000000000000000ed3ce153d4bb5994b09595b20b2315f549081c1e",
          "0x0000000000000000000000002595be55daad0c73b02755539d73283e8b0d7e37",
          "0x0000000000000000000000000000000000000000000000008ac7230489e80000" <>
            "0000000000000000000000000000000000000000000000000000000000000000",
          Events.transfer_with_ui_amount_topic()
        )
      ]

      two_x = TokenTransfers.parse(two_x_logs, true) |> transfer(0)
      zero_multiplier = TokenTransfers.parse(zero_multiplier_logs, true) |> transfer(0)

      assert Decimal.equal?(two_x.amount, Decimal.new("30000000000000000000"))
      assert Decimal.equal?(two_x.ui_value, Decimal.new("60000000000000000000"))
      assert Decimal.equal?(zero_multiplier.amount, Decimal.new("10000000000000000000"))
      assert Decimal.equal?(zero_multiplier.ui_value, Decimal.new(0))
    end

    test "pairs an adjacent UI event emitted after Transfer" do
      result = TokenTransfers.parse([transfer_log(1), ui_log(2, 10, 15)], true)

      assert ui_value(result, 1) == Decimal.new(15)
    end

    test "pairs an adjacent UI event emitted before Transfer" do
      result = TokenTransfers.parse([transfer_log(2), ui_log(1, 10, 15)], true)

      assert ui_value(result, 2) == Decimal.new(15)
    end

    test "pairs mint and burn events using the zero address" do
      logs = [
        transfer_log(1, @token_a, address_topic(@zero), address_topic(@to)),
        ui_log(2, 10, 15, @token_a, address_topic(@zero), address_topic(@to)),
        transfer_log(3, @token_a, address_topic(@to), address_topic(@zero)),
        ui_log(4, 10, 15, @token_a, address_topic(@to), address_topic(@zero))
      ]

      result = TokenTransfers.parse(logs, true)

      assert ui_value(result, 1) == Decimal.new(15)
      assert ui_value(result, 3) == Decimal.new(15)
    end

    test "consumes repeated matching UI events once in log order" do
      logs = [ui_log(4, 10, 16), transfer_log(3), ui_log(2, 10, 15), transfer_log(1)]

      result = TokenTransfers.parse(logs, true)

      assert ui_value(result, 1) == Decimal.new(15)
      assert ui_value(result, 3) == Decimal.new(16)
    end

    test "does not pair events from another token" do
      logs = [transfer_log(1), ui_log(2, 10, 15, @token_b)]

      result = TokenTransfers.parse(logs, true)

      refute Map.has_key?(transfer(result, 1), :ui_value)
    end

    test "does not pair adjacent events when from, to, or raw amount differs" do
      mismatches = [
        ui_log(2, 10, 15, @token_a, address_topic(@to), address_topic(@to)),
        ui_log(2, 10, 15, @token_a, address_topic(@from), address_topic(@from)),
        ui_log(2, 11, 15)
      ]

      for ui_event <- mismatches do
        result = TokenTransfers.parse([transfer_log(1), ui_event], true)

        refute Map.has_key?(transfer(result, 1), :ui_value)
      end
    end

    test "falls back to ordered content matching when logs are not adjacent" do
      unrelated_log = %{ui_log(2, 99, 99, @token_b) | first_topic: "0xdeadbeef"}
      result = TokenTransfers.parse([transfer_log(1), unrelated_log, ui_log(3, 10, 15)], true)

      assert ui_value(result, 1) == Decimal.new(15)
    end

    test "reports an orphan UI event without creating a transfer" do
      handler_id = "scaled-ui-orphan-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:indexer, :scaled_ui, :orphan_ui_event],
          fn event, measurements, metadata, _config ->
            send(test_pid, {event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert %{token_transfers: []} = TokenTransfers.parse([ui_log(1, 10, 15)], true)

      assert_receive {[:indexer, :scaled_ui, :orphan_ui_event], %{count: 1}, %{}}
    end
  end

  defp transfer(result, log_index) do
    Enum.find(result.token_transfers, &(&1.log_index == log_index))
  end

  defp ui_value(result, log_index), do: result |> transfer(log_index) |> Map.fetch!(:ui_value)

  defp transfer_log(index, token \\ @token_a, from \\ address_topic(@from), to \\ address_topic(@to)) do
    base_log(index, token)
    |> Map.merge(%{
      data: uint_data([10]),
      first_topic: TokenTransfer.constant(),
      second_topic: from,
      third_topic: to
    })
  end

  defp ui_log(index, amount, ui_value, token \\ @token_a, from \\ address_topic(@from), to \\ address_topic(@to)) do
    base_log(index, token)
    |> Map.merge(%{
      data: uint_data([amount, ui_value]),
      first_topic: Events.transfer_with_ui_amount_topic(),
      second_topic: from,
      third_topic: to
    })
  end

  defp base_log(index, token) do
    %{
      address_hash: token,
      block_hash: @block_hash,
      block_number: 100,
      fourth_topic: nil,
      index: index,
      transaction_hash: @transaction_hash
    }
  end

  defp hoodi_transfer_log(token, transaction_hash, block_hash, block_number, index, from, to, data, topic) do
    %{
      address_hash: token,
      block_hash: block_hash,
      block_number: block_number,
      data: data,
      first_topic: topic,
      fourth_topic: nil,
      index: index,
      second_topic: from,
      third_topic: to,
      transaction_hash: transaction_hash
    }
  end

  defp address_topic("0x" <> address), do: "0x" <> String.pad_leading(address, 64, "0")

  defp uint_data(values) do
    "0x" <> Enum.map_join(values, &(&1 |> Integer.to_string(16) |> String.pad_leading(64, "0")))
  end
end
