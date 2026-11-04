# SPDX-License-Identifier: LicenseRef-Blockscout
if Application.get_env(:explorer, :chain_type) == :optimism do
  defmodule Indexer.Block.Realtime.FetcherReorgTest do
    use Explorer.DataCase, async: false

    alias Explorer.Chain.Optimism.{FrameSequence, TransactionBatch, Withdrawal}
    alias Indexer.Block.Realtime.Fetcher

    describe "remove_assets_of_replaced_blocks/1" do
      setup do
        stored = insert(:block, number: 100, consensus: true)

        insert_withdrawal(1, 100)
        insert_withdrawal(2, 101)
        insert_frame_sequence(1, 99..101)
        insert_frame_sequence(2, 102..103)

        %{stored: stored}
      end

      test "keeps the optimism assets when the block has the hash stored at its number", %{stored: stored} do
        Fetcher.remove_assets_of_replaced_blocks([
          %{number: 100, hash: to_string(stored.hash), parent_hash: to_string(stored.parent_hash)}
        ])

        assert withdrawal_blocks() == [100, 101]
        assert batch_blocks() == Enum.to_list(99..103)
        assert frame_sequence_ids() == [1, 2]
      end

      test "keeps them for a new block on top of the stored one", %{stored: stored} do
        Fetcher.remove_assets_of_replaced_blocks([
          %{number: 101, hash: to_string(block_hash()), parent_hash: to_string(stored.hash)}
        ])

        assert withdrawal_blocks() == [100, 101]
        assert batch_blocks() == Enum.to_list(99..103)
      end

      test "removes them from the number of a block that replaces another one", %{stored: stored} do
        Fetcher.remove_assets_of_replaced_blocks([
          %{number: 100, hash: to_string(block_hash()), parent_hash: to_string(stored.parent_hash)}
        ])

        assert withdrawal_blocks() == []
        assert batch_blocks() == [99]
        assert frame_sequence_ids() == [1]
      end

      test "removes them from the number below a block whose parent is not the block stored there", %{stored: stored} do
        insert(:block, number: 101, parent_hash: stored.hash, consensus: true)

        Fetcher.remove_assets_of_replaced_blocks([
          %{number: 101, hash: to_string(block_hash()), parent_hash: to_string(block_hash())}
        ])

        assert withdrawal_blocks() == []
        assert batch_blocks() == [99]
        assert frame_sequence_ids() == [1]
      end

      test "removes them from the lowest replaced number", %{stored: stored} do
        insert(:block, number: 101, parent_hash: stored.hash, consensus: true)
        new_hash = to_string(block_hash())

        Fetcher.remove_assets_of_replaced_blocks([
          %{number: 101, hash: to_string(block_hash()), parent_hash: new_hash},
          %{number: 100, hash: new_hash, parent_hash: to_string(stored.parent_hash)}
        ])

        assert withdrawal_blocks() == []
        assert batch_blocks() == [99]
        assert frame_sequence_ids() == [1]
      end
    end

    defp insert_withdrawal(msg_nonce, l2_block_number) do
      Repo.insert!(%Withdrawal{
        msg_nonce: Decimal.new(msg_nonce),
        hash: transaction_hash(),
        l2_transaction_hash: transaction_hash(),
        l2_block_number: l2_block_number
      })
    end

    defp insert_frame_sequence(id, l2_block_numbers) do
      Repo.insert!(%FrameSequence{
        id: id,
        l1_transaction_hashes: [],
        l1_timestamp: DateTime.utc_now(),
        view_ready: true
      })

      Enum.each(l2_block_numbers, fn number ->
        Repo.insert!(%TransactionBatch{l2_block_number: number, frame_sequence_id: id, frame_sequence_id_prev: 0})
      end)
    end

    defp withdrawal_blocks, do: Repo.all(from(w in Withdrawal, select: w.l2_block_number, order_by: w.l2_block_number))

    defp batch_blocks,
      do: Repo.all(from(tb in TransactionBatch, select: tb.l2_block_number, order_by: tb.l2_block_number))

    defp frame_sequence_ids, do: Repo.all(from(fs in FrameSequence, select: fs.id, order_by: fs.id))
  end
end
