defmodule Indexer.Fetcher.ScaledUiEnrichmentTest do
  use Explorer.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Explorer.Chain.{Block, Hash, ScaledUiMultiplierUpdate, TokenTransfer}
  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.ScaledUi.{BackfillGap, Events, TokenState}
  alias Explorer.Migrator.{MigrationStatus, ScaledUiBackfill}
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

  test "updates only the transfer identified by transaction hash, block hash, and log index" do
    block = insert(:block, consensus: true)
    selected_transfer = insert_unknown_transfer(Decimal.new(6), block: block, log_index: 10)
    untouched_transfer = insert_unknown_transfer(Decimal.new(7), block: block, log_index: 10)
    insert_multiplier(selected_transfer, Decimal.new("3000000000000000000"))

    candidate =
      10
      |> ScaledUiEnrichment.candidates()
      |> Enum.find(&(&1.token_contract_address_hash == selected_transfer.token_contract_address_hash))
      |> Map.put(:transaction_hash, selected_transfer.transaction_hash)

    assert {:ok, 1} = ScaledUiEnrichment.enrich_candidates([candidate])

    assert_transfer(selected_transfer, "ok", "3000000000000000000")
    assert_transfer(untouched_transfer, "unknown", nil)
  end

  test "advances past an unresolved first page" do
    previous_config = Application.get_env(:indexer, ScaledUiEnrichment)
    Application.put_env(:indexer, ScaledUiEnrichment, batch_size: 1, interval: :timer.minutes(1))

    on_exit(fn -> Application.put_env(:indexer, ScaledUiEnrichment, previous_config) end)

    _unresolved_transfer = insert_unknown_transfer(Decimal.new(6))
    resolvable_transfer = insert_unknown_transfer(Decimal.new(6))
    insert_multiplier(resolvable_transfer, Decimal.new("3000000000000000000"))

    name = Module.concat(__MODULE__, "Worker#{System.unique_integer([:positive])}")
    assert {:ok, pid} = ScaledUiEnrichment.start_link([], name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_eventually(fn ->
      updated = transfer_by_id(resolvable_transfer)
      updated.ui_amount_status == "ok"
    end)
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
    put_backfill_target_head(20)
    BackfillGap.put_ranges(Repo, token.contract_address_hash, [%{from_block: 10, to_block: 20}], now: now)

    assert :ok = ScaledUiEnrichment.retry_backfill_gaps(batch_size: 1)
    assert BackfillGap.count() == 0
  end

  test "retries a gap only through the migration's fixed target head" do
    token = insert(:token)
    target_block = insert(:block, number: 10, consensus: true)
    block = insert(:block, number: 11, consensus: true)
    transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    target_head = target_block.number
    now = DateTime.utc_now()

    insert(:log,
      address: token.contract_address,
      block: block,
      block_number: block.number,
      first_topic: topic(Events.transfer_with_ui_amount_topic()),
      transaction: transaction
    )

    put_backfill_target_head(target_head)

    BackfillGap.put_ranges(
      Repo,
      token.contract_address_hash,
      [%{from_block: target_head, to_block: target_head}],
      now: now
    )

    assert :ok = ScaledUiEnrichment.retry_backfill_gaps(batch_size: 1)
    assert BackfillGap.count() == 0
    assert Repo.get(TokenState, token.contract_address_hash) == nil
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

  test "backs off instead of retrying against the current head when the migration target is unavailable" do
    token = insert(:token)
    now = DateTime.utc_now()
    BackfillGap.put_ranges(Repo, token.contract_address_hash, [%{from_block: 10, to_block: 20}], now: now)

    assert :ok = ScaledUiEnrichment.retry_backfill_gaps(batch_size: 1)

    gap = Repo.one!(BackfillGap)
    assert gap.retry_count == 1
    assert gap.last_error == ":backfill_target_head_unavailable"
    assert Repo.get(TokenState, token.contract_address_hash) == nil
  end

  test "stops a replay whose heartbeat loses claim ownership" do
    Sandbox.mode(Repo, {:shared, self()})

    token = insert(:token)
    block = insert(:block, number: 10, consensus: true)
    transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    now = DateTime.utc_now()

    insert(:log,
      address: token.contract_address,
      block: block,
      block_number: block.number,
      first_topic: topic(Events.transfer_with_ui_amount_topic()),
      transaction: transaction
    )

    put_backfill_target_head(block.number)
    BackfillGap.put_ranges(Repo, token.contract_address_hash, [%{from_block: 10, to_block: 10}], now: now)

    parent = self()
    replacement_lease_id = Ecto.UUID.generate()

    renew_claim = fn claim, _options ->
      from(gap in BackfillGap,
        where: gap.token_contract_address_hash == ^claim.token_contract_address_hash,
        where: gap.lease_id == ^claim.lease_id
      )
      |> Repo.update_all(set: [lease_id: replacement_lease_id])

      send(parent, :lease_replaced)
      {0, nil}
    end

    backfill = fn _claim, cancellation_check ->
      receive do
        :lease_replaced -> cancellation_check.()
      after
        1_000 -> {:error, :heartbeat_not_observed}
      end
    end

    assert :ok =
             ScaledUiEnrichment.retry_backfill_gaps(
               backfill: backfill,
               batch_size: 1,
               heartbeat_interval: 0,
               lease_seconds: 1,
               renew_claim: renew_claim
             )

    assert Repo.get(TokenState, token.contract_address_hash) == nil
    assert Repo.one!(BackfillGap).lease_id == replacement_lease_id
  end

  test "treats a crashed heartbeat as a lost claim" do
    Sandbox.mode(Repo, {:shared, self()})

    token = insert(:token)
    now = DateTime.utc_now()
    put_backfill_target_head(10)
    BackfillGap.put_ranges(Repo, token.contract_address_hash, [%{from_block: 10, to_block: 10}], now: now)

    parent = self()

    renew_claim = fn _claim, _options ->
      send(parent, :renew_attempted)
      exit(:heartbeat_failed)
    end

    backfill = fn _claim, cancellation_check ->
      receive do
        :renew_attempted -> cancellation_check.()
      after
        1_000 -> {:error, :heartbeat_not_observed}
      end
    end

    assert :ok =
             ScaledUiEnrichment.retry_backfill_gaps(
               backfill: backfill,
               batch_size: 1,
               heartbeat_interval: 0,
               lease_seconds: 1,
               renew_claim: renew_claim
             )

    gap = Repo.one!(BackfillGap)
    assert gap.retry_count == 1
    assert gap.last_error == ":backfill_claim_lost"
  end

  defp insert_unknown_transfer(ui_value, options \\ []) do
    block = Keyword.get_lazy(options, :block, fn -> insert(:block, consensus: true) end)
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
        log_index: Keyword.get(options, :log_index, 10),
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

  defp put_backfill_target_head(target_head) do
    assert {:ok, _status} = MigrationStatus.set_status(ScaledUiBackfill.migration_name(), "started")
    assert {:ok, _status} = MigrationStatus.set_meta(ScaledUiBackfill.migration_name(), %{"target_head" => target_head})
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
    updated = transfer_by_id(transfer)

    assert updated.ui_amount_status == status

    if multiplier do
      assert Decimal.equal?(updated.ui_multiplier, Decimal.new(multiplier))
    else
      assert updated.ui_multiplier == nil
    end
  end

  defp transfer_by_id(transfer) do
    Repo.get_by!(TokenTransfer,
      transaction_hash: transfer.transaction_hash,
      block_hash: transfer.block_hash,
      log_index: transfer.log_index
    )
  end

  defp assert_eventually(assertion, attempts \\ 20)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")

  defp topic(value) do
    {:ok, topic} = Hash.Full.cast(value)
    topic
  end
end
