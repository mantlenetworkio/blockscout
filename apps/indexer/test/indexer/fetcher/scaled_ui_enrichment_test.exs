defmodule Indexer.Fetcher.ScaledUiEnrichmentTest do
  use Explorer.DataCase, async: false

  import Ecto.Query

  alias Explorer.Chain.{Block, ScaledUiMultiplierUpdate, TokenTransfer}
  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.ScaledUi.{BackfillGap, TokenState}
  alias Explorer.Repo
  alias Explorer.Utility.MissingBlockRange
  alias Indexer.Fetcher.ScaledUiEnrichment

  setup do
    BackgroundMigrations.set_heavy_indexes_create_token_transfers_ui_amount_status_unknown_index_finished(true)

    on_exit(fn ->
      BackgroundMigrations.set_heavy_indexes_create_token_transfers_ui_amount_status_unknown_index_finished(false)
    end)

    :ok
  end

  test "re-judges unknown transfers after their multiplier timeline is available" do
    ok_transfer = insert_unknown_transfer(Decimal.new(6))
    mismatch_transfer = insert_unknown_transfer(Decimal.new(7))

    insert_multiplier(ok_transfer, Decimal.new("3000000000000000000"))
    insert_multiplier(mismatch_transfer, Decimal.new("3000000000000000000"))

    assert {:ok, 2} = ScaledUiEnrichment.enrich_batch()

    assert_transfer(ok_transfer, "ok", "3000000000000000000")
    assert_transfer(mismatch_transfer, "mismatch", "3000000000000000000")
  end

  test "leaves a transfer unknown while the timeline still has no trusted multiplier" do
    transfer = insert_unknown_transfer(Decimal.new(6))
    original_updated_at = transfer.updated_at

    assert {:ok, 0} = ScaledUiEnrichment.enrich_batch()

    unchanged = Repo.get_by!(TokenTransfer, block_hash: transfer.block_hash, log_index: transfer.log_index)
    assert unchanged.ui_amount_status == "unknown"
    assert unchanged.ui_multiplier == nil
    assert unchanged.updated_at == original_updated_at
  end

  test "does not scan transfers before the capability boundary" do
    transfer = insert_unknown_transfer(Decimal.new(6), capability_offset: 1)
    insert_multiplier(transfer, Decimal.new("3000000000000000000"))

    assert {:ok, 0} = ScaledUiEnrichment.enrich_batch()
    assert_transfer(transfer, "unknown", nil)
  end

  test "does not update an orphaned transfer selected before a reorg" do
    transfer = insert_unknown_transfer(Decimal.new(6))
    insert_multiplier(transfer, Decimal.new("3000000000000000000"))
    candidates = ScaledUiEnrichment.candidates(500)

    from(block in Block, where: block.hash == ^transfer.block_hash)
    |> Repo.update_all(set: [consensus: false])

    assert {:ok, 0} = ScaledUiEnrichment.enrich_candidates(candidates)
    assert_transfer(transfer, "unknown", nil)
  end

  test "does not overwrite a status changed after candidate selection" do
    transfer = insert_unknown_transfer(Decimal.new(6))
    insert_multiplier(transfer, Decimal.new("3000000000000000000"))
    candidates = ScaledUiEnrichment.candidates(500)

    from(current in TokenTransfer,
      where: current.block_hash == ^transfer.block_hash,
      where: current.log_index == ^transfer.log_index
    )
    |> Repo.update_all(set: [ui_amount_status: "mismatch"])

    assert {:ok, 0} = ScaledUiEnrichment.enrich_candidates(candidates)
    assert_transfer(transfer, "mismatch", nil)
  end

  test "waits for the partial index before scanning" do
    transfer = insert_unknown_transfer(Decimal.new(6))
    insert_multiplier(transfer, Decimal.new("3000000000000000000"))

    BackgroundMigrations.set_heavy_indexes_create_token_transfers_ui_amount_status_unknown_index_finished(false)

    assert {:ok, 0} = ScaledUiEnrichment.enrich_batch()
    assert_transfer(transfer, "unknown", nil)
  end

  test "retries claimed backfill gaps after normal block coverage is restored" do
    token = insert(:token)
    now = DateTime.utc_now()
    BackfillGap.put_ranges(Repo, token.contract_address_hash, [%{from_block: 10, to_block: 20}], now: now)

    assert :ok = ScaledUiEnrichment.retry_backfill_gaps(batch_size: 1)
    assert BackfillGap.count() == 0
  end

  test "backs off a claimed gap while its block range is still missing" do
    token = insert(:token)
    now = DateTime.utc_now()
    BackfillGap.put_ranges(Repo, token.contract_address_hash, [%{from_block: 10, to_block: 20}], now: now)

    %MissingBlockRange{}
    |> MissingBlockRange.changeset(%{from_number: 20, to_number: 10})
    |> Repo.insert!()

    assert :ok = ScaledUiEnrichment.retry_backfill_gaps(batch_size: 1)

    gap = Repo.one!(BackfillGap)
    assert gap.retry_count == 1
    assert gap.last_error == ":block_range_still_missing"
  end

  defp insert_unknown_transfer(ui_value, options \\ []) do
    block = insert(:block, consensus: true)
    token = insert(:token)
    from_address = insert(:address)
    to_address = insert(:address)

    transaction =
      insert(:transaction,
        from_address: from_address,
        to_address: token.contract_address
      )
      |> with_block(block, cumulative_gas_used: 1, gas_used: 1)

    transfer =
      insert(:token_transfer,
        amount: Decimal.new(2),
        block: block,
        block_number: block.number,
        from_address: from_address,
        log_index: 10,
        to_address: to_address,
        token_contract_address: token.contract_address,
        token_type: token.type,
        transaction: transaction,
        ui_value: ui_value,
        ui_amount_status: "unknown"
      )
      |> Repo.preload([:block, :transaction])

    capability_block = transfer.block_number + Keyword.get(options, :capability_offset, 0)

    %TokenState{}
    |> TokenState.changeset(%{
      token_contract_address_hash: transfer.token_contract_address_hash,
      capability_block: capability_block
    })
    |> Repo.insert!()

    transfer
  end

  defp insert_multiplier(transfer, multiplier) do
    block_timestamp = Decimal.new(DateTime.to_unix(transfer.block.timestamp))

    %ScaledUiMultiplierUpdate{}
    |> ScaledUiMultiplierUpdate.changeset(%{
      token_contract_address_hash: transfer.token_contract_address_hash,
      transaction_hash: transfer.transaction_hash,
      block_hash: transfer.block_hash,
      log_index: 1,
      block_number: transfer.block_number,
      block_timestamp: block_timestamp,
      event_type: "updated",
      old_multiplier: Decimal.new(0),
      new_multiplier: multiplier,
      effective_at: block_timestamp
    })
    |> Repo.insert!()
  end

  defp assert_transfer(transfer, status, multiplier) do
    updated = Repo.get_by!(TokenTransfer, block_hash: transfer.block_hash, log_index: transfer.log_index)

    assert updated.ui_amount_status == status

    if multiplier do
      assert Decimal.equal?(updated.ui_multiplier, Decimal.new(multiplier))
    else
      assert updated.ui_multiplier == nil
    end
  end
end
