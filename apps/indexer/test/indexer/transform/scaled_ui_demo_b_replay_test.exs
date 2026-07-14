defmodule Indexer.Transform.ScaledUiDemoBReplayTest do
  use Explorer.DataCase

  alias Explorer.Chain.ScaledUi.{Status, Timeline}
  alias Explorer.Chain.ScaledUi.Events
  alias Explorer.Chain.TokenTransfer
  alias Indexer.Transform.{ScaledUiMultiplierUpdates, TokenTransfers}

  @scale 1_000_000_000_000_000_000
  @token "0xdbc72597b42bbe0d3345d4334f4be0fceae57a58"
  @zero_topic "0x" <> String.duplicate("0", 64)
  @issuer_topic "0x" <> String.pad_leading("2ba2a5519153ff68e6c2216c44a9c7b1488fbfbe", 64, "0")
  @user1_topic "0x" <> String.pad_leading("ed3ce153d4bb5994b09595b20b2315f549081c1e", 64, "0")
  @user2_topic "0x" <> String.pad_leading("2595be55daad0c73b02755539d73283e8b0d7e37", 64, "0")

  test "replays the canonical DEMO-B initialization through the 3x transfer" do
    logs = demo_logs()

    block_timestamps =
      logs
      |> Map.new(&{&1.block_number, DateTime.from_unix!(&1.block_timestamp)})

    updates = ScaledUiMultiplierUpdates.parse(logs, block_timestamps)
    capability_rows = ScaledUiMultiplierUpdates.capability_rows(logs)
    %{token_transfers: transfers} = TokenTransfers.parse(logs, true)

    assert length(updates) == 2
    assert capability_rows == [%{token_contract_address_hash: @token, capability_block: hex("0x271f9aa")}]
    assert length(transfers) == 4

    snapshots =
      transfers
      |> Enum.sort_by(&{&1.block_number, &1.log_index})
      |> Enum.map(fn transfer ->
        multiplier =
          Timeline.multiplier_at(
            updates,
            transfer.block_number,
            transfer.log_index,
            block_timestamps
            |> Map.fetch!(transfer.block_number)
            |> DateTime.to_unix()
            |> Decimal.new()
          )

        assert Status.judge(transfer.amount, transfer.ui_value, multiplier) == :ok
        {Decimal.to_integer(transfer.amount), Decimal.to_integer(transfer.ui_value), Decimal.to_integer(multiplier)}
      end)

    assert snapshots == [
             {1_000 * @scale, 1_000 * @scale, @scale},
             {400 * @scale, 400 * @scale, @scale},
             {100 * @scale, 100 * @scale, @scale},
             {50 * @scale, 150 * @scale, 3 * @scale}
           ]

    summary = Timeline.replay(updates)
    assert {:ok, multiplier} = Timeline.current_multiplier(summary, Decimal.new(hex("0x6a4f768b")))
    assert Decimal.equal?(multiplier, Decimal.new(3 * @scale))
  end

  defp demo_logs do
    [
      updated_log(
        "0x271f9aa",
        "0x6a4f7635",
        "0x4070cec02d62047eebef71a7f2decd2910cfb3ecaaef06e1718660ad38194786",
        "0x2e33e3c7ecfaa4f8bf75e776f39b140f6723908aa2649c4588a8adb2be714852",
        2,
        0,
        @scale,
        hex("0x6a4f7635")
      ),
      transfer_log(
        "0x271f9b0",
        "0x6a4f7641",
        "0x2b3cf912d1b9d2a6ad046d96814043a1c8b4b1f8ce1f8069e9a4e460a4eff52a",
        "0x719b56c674349f08ff31caad782e2e78e14eeec798ce085a2995777e277d97f6",
        0,
        @zero_topic,
        @issuer_topic,
        1_000 * @scale
      ),
      ui_log(
        "0x271f9b0",
        "0x6a4f7641",
        "0x2b3cf912d1b9d2a6ad046d96814043a1c8b4b1f8ce1f8069e9a4e460a4eff52a",
        "0x719b56c674349f08ff31caad782e2e78e14eeec798ce085a2995777e277d97f6",
        1,
        @zero_topic,
        @issuer_topic,
        1_000 * @scale,
        1_000 * @scale
      ),
      transfer_log(
        "0x271f9b4",
        "0x6a4f7649",
        "0xb8370b7a98b2d5b4b9beeba61616ec229ed70383902da60f161b6f707a2cc90b",
        "0x7ff25c0a3fa2223f5da98a8a4527b9afd3e989d218bb456e8fd64b43bd4be4ff",
        0,
        @issuer_topic,
        @user1_topic,
        400 * @scale
      ),
      ui_log(
        "0x271f9b4",
        "0x6a4f7649",
        "0xb8370b7a98b2d5b4b9beeba61616ec229ed70383902da60f161b6f707a2cc90b",
        "0x7ff25c0a3fa2223f5da98a8a4527b9afd3e989d218bb456e8fd64b43bd4be4ff",
        1,
        @issuer_topic,
        @user1_topic,
        400 * @scale,
        400 * @scale
      ),
      transfer_log(
        "0x271f9b6",
        "0x6a4f764d",
        "0xa92c2c164a21eb7fd383726f5f6bedf0388a370026feb36ad612cd6ef302b1b1",
        "0xba26613e8a0f2433af903c223335658f9a74b34d3e7c7f9619fb8643f87afedd",
        0,
        @user1_topic,
        @user2_topic,
        100 * @scale
      ),
      ui_log(
        "0x271f9b6",
        "0x6a4f764d",
        "0xa92c2c164a21eb7fd383726f5f6bedf0388a370026feb36ad612cd6ef302b1b1",
        "0xba26613e8a0f2433af903c223335658f9a74b34d3e7c7f9619fb8643f87afedd",
        1,
        @user1_topic,
        @user2_topic,
        100 * @scale,
        100 * @scale
      ),
      updated_log(
        "0x271f9b9",
        "0x6a4f7653",
        "0xfa9665b918862a5c5b8e7cd0c7a47b9f4bee09bf78d75111a8de7f5bb48e3cdc",
        "0xe058a00bd056a46194626a56bd38c771e5bf608d7fe5bd33bf2c599a63aa97c4",
        10,
        @scale,
        3 * @scale,
        hex("0x6a4f767a")
      ),
      transfer_log(
        "0x271f9d5",
        "0x6a4f768b",
        "0x44a8d29cad30535343ac98f9f06c90b2b50c875e64712e9f46c277fdda127526",
        "0x9914521c81a9798fe8c731ae665f5e084e5c2393a46f53bd720867491439d44c",
        2,
        @user1_topic,
        @user2_topic,
        50 * @scale
      ),
      ui_log(
        "0x271f9d5",
        "0x6a4f768b",
        "0x44a8d29cad30535343ac98f9f06c90b2b50c875e64712e9f46c277fdda127526",
        "0x9914521c81a9798fe8c731ae665f5e084e5c2393a46f53bd720867491439d44c",
        3,
        @user1_topic,
        @user2_topic,
        50 * @scale,
        150 * @scale
      )
    ]
  end

  defp updated_log(block, timestamp, block_hash, transaction_hash, index, old, new, effective_at) do
    base_log(block, timestamp, block_hash, transaction_hash, index)
    |> Map.merge(%{
      data: uint_data([old, new, effective_at]),
      first_topic: Events.ui_multiplier_updated_topic()
    })
  end

  defp transfer_log(block, timestamp, block_hash, transaction_hash, index, from, to, amount) do
    base_log(block, timestamp, block_hash, transaction_hash, index)
    |> Map.merge(%{
      data: uint_data([amount]),
      first_topic: TokenTransfer.constant(),
      second_topic: from,
      third_topic: to
    })
  end

  defp ui_log(block, timestamp, block_hash, transaction_hash, index, from, to, amount, ui_value) do
    base_log(block, timestamp, block_hash, transaction_hash, index)
    |> Map.merge(%{
      data: uint_data([amount, ui_value]),
      first_topic: Events.transfer_with_ui_amount_topic(),
      second_topic: from,
      third_topic: to
    })
  end

  defp base_log(block, timestamp, block_hash, transaction_hash, index) do
    %{
      address_hash: @token,
      block_hash: block_hash,
      block_number: hex(block),
      block_timestamp: hex(timestamp),
      first_topic: nil,
      second_topic: nil,
      third_topic: nil,
      fourth_topic: nil,
      index: index,
      transaction_hash: transaction_hash
    }
  end

  defp uint_data(values) do
    "0x" <> Enum.map_join(values, &(&1 |> Integer.to_string(16) |> String.pad_leading(64, "0")))
  end

  defp hex("0x" <> value), do: String.to_integer(value, 16)
end
