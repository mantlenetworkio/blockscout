defmodule Explorer.Migrator.ScaledUiBackfillTest do
  use Explorer.DataCase, async: false

  alias Explorer.Chain.{Hash, ScaledUiMultiplierUpdate, TokenTransfer}
  alias Explorer.Chain.ScaledUi.{BackfillGap, Events, TokenState}
  alias Explorer.Migrator.{MigrationStatus, ScaledUiBackfill}
  alias Explorer.Repo
  alias Explorer.Utility.MissingBlockRange

  setup do
    first_block = Application.get_env(:indexer, :first_block)
    block_ranges = Application.get_env(:indexer, :block_ranges)
    backfill_config = Application.get_env(:explorer, ScaledUiBackfill)
    Application.put_env(:indexer, :first_block, 0)
    Application.put_env(:indexer, :block_ranges, "0..latest")
    Application.put_env(:explorer, ScaledUiBackfill, batch_size: 1, concurrency: 1, transfer_batch_size: 1)

    on_exit(fn ->
      Application.put_env(:indexer, :first_block, first_block)
      Application.put_env(:indexer, :block_ranges, block_ranges)
      Application.put_env(:explorer, ScaledUiBackfill, backfill_config)
    end)

    :ok
  end

  test "backfills timeline, paired snapshots, missing events, and preserves pre-capability rows" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    from_address = insert(:address)
    to_address = insert(:address)

    paired = insert_transfer(token, block, transaction, from_address, to_address, 10)
    missing = insert_transfer(token, block, transaction, from_address, to_address, 20)

    earlier_block = insert(:block, number: block.number - 1, consensus: true)
    earlier_transaction = insert(:transaction) |> with_block(earlier_block, cumulative_gas_used: 1, gas_used: 1)
    before_capability = insert_transfer(token, earlier_block, earlier_transaction, from_address, to_address, 5)

    insert_multiplier_log(token, block, transaction, 1, "3000000000000000000")
    insert_ui_log(token, block, transaction, from_address, to_address, 11, 2, 6)

    assert {:ok, %{updated_transfers: 2}} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    paired = reload(paired)
    assert Decimal.equal?(paired.ui_value, Decimal.new(6))
    assert Decimal.equal?(paired.ui_multiplier, Decimal.new("3000000000000000000"))
    assert paired.ui_amount_status == "ok"

    missing = reload(missing)
    assert missing.ui_value == nil
    assert Decimal.equal?(missing.ui_multiplier, Decimal.new("3000000000000000000"))
    assert missing.ui_amount_status == "event_missing"

    assert reload(before_capability).ui_amount_status == nil
    assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 1

    state = Repo.get!(TokenState, token.contract_address_hash)
    assert state.capability_block == block.number
    assert state.timeline_status == "ok"

    assert {:ok, %{updated_transfers: 0}} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 1
  end

  test "defers transfer replay and registers a retry while block coverage is missing" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    from_address = insert(:address)
    to_address = insert(:address)
    transfer = insert_transfer(token, block, transaction, from_address, to_address, 10)

    insert_multiplier_log(token, block, transaction, 1, "3000000000000000000")
    insert_ui_log(token, block, transaction, from_address, to_address, 11, 2, 6)

    %MissingBlockRange{}
    |> MissingBlockRange.changeset(%{from_number: block.number, to_number: block.number})
    |> Repo.insert!()

    assert {:ok, _result} = ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    transfer = reload(transfer)
    assert transfer.ui_value == nil
    assert transfer.ui_multiplier == nil
    assert transfer.ui_amount_status == nil
    assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 0

    gap = Repo.one!(BackfillGap)
    assert gap.from_block == block.number
    assert gap.to_block == block.number

    Repo.delete_all(MissingBlockRange)
    assert {:ok, _result} = ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    transfer = reload(transfer)
    assert Decimal.equal?(transfer.ui_multiplier, Decimal.new("3000000000000000000"))
    assert transfer.ui_amount_status == "ok"
  end

  test "updates duplicate log indexes by the full token transfer identity" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    from_address = insert(:address)
    to_address = insert(:address)

    first_transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    second_transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)

    first_transfer = insert_transfer(token, block, first_transaction, from_address, to_address, 10)
    second_transfer = insert_transfer(token, block, second_transaction, from_address, to_address, 10)

    insert_multiplier_log(token, block, first_transaction, 1, "3000000000000000000")
    insert_ui_log(token, block, first_transaction, from_address, to_address, 11, 2, 6)
    insert_ui_log(token, block, second_transaction, from_address, to_address, 11, 2, 8)

    assert {:ok, %{updated_transfers: 2}} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    assert Decimal.equal?(reload(first_transfer).ui_value, Decimal.new(6))
    assert Decimal.equal?(reload(second_transfer).ui_value, Decimal.new(8))
  end

  test "uses an internal contract creation as the coverage lower bound" do
    token = insert(:token)
    creation_block = insert(:block, consensus: true)

    creation_transaction =
      insert(:transaction) |> with_block(creation_block, cumulative_gas_used: 1, gas_used: 1)

    insert(:internal_transaction_create,
      block_number: creation_block.number,
      created_contract_address: token.contract_address,
      index: 1,
      transaction: creation_transaction,
      transaction_index: creation_transaction.index
    )

    capability_block = insert(:block, number: creation_block.number + 2, consensus: true)

    capability_transaction =
      insert(:transaction) |> with_block(capability_block, cumulative_gas_used: 1, gas_used: 1)

    insert_multiplier_log(token, capability_block, capability_transaction, 1, "3000000000000000000")

    %MissingBlockRange{}
    |> MissingBlockRange.changeset(%{
      from_number: creation_block.number + 1,
      to_number: creation_block.number + 1
    })
    |> Repo.insert!()

    assert {:ok, _result} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, capability_block.number)

    gap = Repo.one!(BackfillGap)
    assert gap.from_block == creation_block.number + 1
    assert gap.to_block == creation_block.number + 1
  end

  test "ignores an internal creation whose parent transaction is not canonical" do
    token = insert(:token)
    creation_block = insert(:block, consensus: true)

    orphaned_creation_transaction =
      insert(:transaction)
      |> with_block(creation_block,
        block_consensus: false,
        cumulative_gas_used: 1,
        gas_used: 1
      )

    insert(:internal_transaction_create,
      block_number: creation_block.number,
      created_contract_address: token.contract_address,
      index: 1,
      transaction: orphaned_creation_transaction,
      transaction_index: orphaned_creation_transaction.index
    )

    capability_block = insert(:block, number: creation_block.number + 2, consensus: true)

    capability_transaction =
      insert(:transaction) |> with_block(capability_block, cumulative_gas_used: 1, gas_used: 1)

    insert_multiplier_log(token, capability_block, capability_transaction, 1, "3000000000000000000")

    %MissingBlockRange{}
    |> MissingBlockRange.changeset(%{
      from_number: creation_block.number + 1,
      to_number: creation_block.number + 1
    })
    |> Repo.insert!()

    assert {:ok, _result} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, capability_block.number)

    assert BackfillGap.count() == 0
  end

  test "re-judges a non-unknown snapshot after historical data is repaired" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    from_address = insert(:address)
    to_address = insert(:address)

    transfer =
      token
      |> insert_transfer(block, transaction, from_address, to_address, 10)
      |> Ecto.Changeset.change(
        ui_amount_status: "mismatch",
        ui_multiplier: Decimal.new("3000000000000000000"),
        ui_value: Decimal.new(5)
      )
      |> Repo.update!()

    insert_multiplier_log(token, block, transaction, 1, "3000000000000000000")
    ui_log = insert_ui_log(token, block, transaction, from_address, to_address, 11, 2, 6)

    assert {:ok, %{updated_transfers: 1}} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    transfer = reload(transfer)
    assert Decimal.equal?(transfer.ui_value, Decimal.new(6))
    assert transfer.ui_amount_status == "ok"

    Repo.delete!(ui_log)

    assert {:ok, %{updated_transfers: 1}} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    transfer = reload(transfer)
    assert transfer.ui_value == nil
    assert transfer.ui_amount_status == "event_missing"
  end

  test "continues transfer backfill across transaction batches" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    from_address = insert(:address)
    to_address = insert(:address)

    transactions =
      Enum.map(1..2, fn _index ->
        insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
      end)

    [first_transaction, second_transaction] = transactions
    first_transfer = insert_transfer(token, block, first_transaction, from_address, to_address, 10)
    second_transfer = insert_transfer(token, block, second_transaction, from_address, to_address, 20)

    insert_multiplier_log(token, block, first_transaction, 1, "3000000000000000000")
    insert_ui_log(token, block, first_transaction, from_address, to_address, 11, 2, 6)
    insert_ui_log(token, block, second_transaction, from_address, to_address, 21, 2, 6)

    assert {:ok, %{updated_transfers: 2}} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)

    assert reload(first_transfer).ui_amount_status == "ok"
    assert reload(second_transfer).ui_amount_status == "ok"
  end

  test "stops between transfer batches after cancellation" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    from_address = insert(:address)
    to_address = insert(:address)

    first_transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    second_transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)

    transfers = [
      insert_transfer(token, block, first_transaction, from_address, to_address, 10),
      insert_transfer(token, block, second_transaction, from_address, to_address, 20)
    ]

    insert_multiplier_log(token, block, first_transaction, 1, "3000000000000000000")
    insert_ui_log(token, block, first_transaction, from_address, to_address, 11, 2, 6)
    insert_ui_log(token, block, second_transaction, from_address, to_address, 21, 2, 6)

    counter_key = make_ref()
    Process.put(counter_key, 0)

    cancellation_check = fn ->
      check_count = Process.get(counter_key) + 1
      Process.put(counter_key, check_count)

      if check_count < 3, do: :ok, else: {:error, :backfill_claim_lost}
    end

    assert {:error, :backfill_claim_lost} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number,
               cancellation_check: cancellation_check
             )

    assert Enum.count(transfers, &(reload(&1).ui_amount_status != nil)) == 1
  end

  test "serializes concurrent backfills for the same token" do
    token = insert(:token)
    parent = self()

    lock_task =
      Task.async(fn ->
        connection_options =
          Keyword.take(Repo.config(), [:database, :hostname, :password, :port, :socket_options, :ssl, :username])

        {:ok, connection} = Postgrex.start_link(connection_options)

        try do
          Postgrex.query!(connection, "SELECT pg_advisory_lock(hashtextextended($1, 0))", [
            "scaled_ui_backfill:" <> to_string(token.contract_address_hash)
          ])

          send(parent, :token_locked)

          receive do
            :unlock_token -> :ok
          end

          Postgrex.query!(connection, "SELECT pg_advisory_unlock(hashtextextended($1, 0))", [
            "scaled_ui_backfill:" <> to_string(token.contract_address_hash)
          ])
        after
          GenServer.stop(connection)
        end
      end)

    assert_receive :token_locked
    backfill_task = Task.async(fn -> ScaledUiBackfill.backfill_token(token.contract_address_hash, 0) end)
    assert Task.yield(backfill_task, 100) == nil

    send(lock_task.pid, :unlock_token)
    Task.await(lock_task)
    assert {:ok, _result} = Task.await(backfill_task)
  end

  test "stops before the next batch when the canonical target changes" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    from_address = insert(:address)
    to_address = insert(:address)

    first_transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    second_transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)

    insert_transfer(token, block, first_transaction, from_address, to_address, 10)
    insert_transfer(token, block, second_transaction, from_address, to_address, 20)
    insert_multiplier_log(token, block, first_transaction, 1, "3000000000000000000")
    insert_ui_log(token, block, first_transaction, from_address, to_address, 11, 2, 6)
    insert_ui_log(token, block, second_transaction, from_address, to_address, 21, 2, 6)

    Repo.query!("""
    CREATE FUNCTION scaled_ui_test_change_canonical_target() RETURNS trigger AS $$
    BEGIN
      UPDATE blocks SET consensus = FALSE WHERE hash = NEW.block_hash;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER scaled_ui_test_change_canonical_target
    AFTER UPDATE OF ui_amount_status ON token_transfers
    FOR EACH ROW EXECUTE FUNCTION scaled_ui_test_change_canonical_target()
    """)

    assert {:error, :canonical_anchor_changed} =
             ScaledUiBackfill.backfill_token(token.contract_address_hash, block.number)
  end

  test "validates the deferred transfer status constraint on finish" do
    assert :ok = ScaledUiBackfill.on_finish()

    assert [[true]] ==
             Repo.query!("SELECT convalidated FROM pg_constraint WHERE conname = 'ui_amount_status_known'").rows
  end

  test "fixes the target head in migration identifiers" do
    token = insert(:token)
    block = insert(:block, consensus: true)
    transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    insert_multiplier_log(token, block, transaction, 1, "3000000000000000000")

    assert {[{token_hash, target_head}], state} = ScaledUiBackfill.last_unprocessed_identifiers(%{})
    assert token_hash == token.contract_address_hash
    assert target_head == block.number
    assert state["target_head"] == block.number
  end

  test "persists the target head before returning the first migration batch" do
    assert {:ok, _status} = MigrationStatus.set_status(ScaledUiBackfill.migration_name(), "started")
    block = insert(:block, consensus: true)

    assert {_identifiers, %{"target_head" => target_head}} =
             ScaledUiBackfill.last_unprocessed_identifiers(%{})

    assert target_head == block.number
    assert MigrationStatus.fetch(ScaledUiBackfill.migration_name()).meta["target_head"] == block.number
  end

  test "resumes token discovery after the persisted hash cursor" do
    block = insert(:block, consensus: true)
    transaction = insert(:transaction) |> with_block(block, cumulative_gas_used: 1, gas_used: 1)
    tokens = Enum.map(1..2, fn _index -> insert(:token) end)

    tokens
    |> Enum.with_index(1)
    |> Enum.each(fn {token, index} ->
      insert_multiplier_log(token, block, transaction, index, "3000000000000000000")
    end)

    sorted_hashes = tokens |> Enum.map(& &1.contract_address_hash) |> Enum.sort_by(&to_string/1)

    assert {[first_identifier], first_state} = ScaledUiBackfill.last_unprocessed_identifiers(%{})
    assert {List.first(sorted_hashes), block.number} == first_identifier

    assert {[second_identifier], second_state} =
             ScaledUiBackfill.last_unprocessed_identifiers(first_state)

    assert {List.last(sorted_hashes), block.number} == second_identifier
    assert {[], ^second_state} = ScaledUiBackfill.last_unprocessed_identifiers(second_state)
  end

  test "keeps the migration pending until registered gaps are cleared" do
    token = insert(:token)
    block = insert(:block, consensus: true)

    BackfillGap.put_ranges(Repo, token.contract_address_hash, [
      %{from_block: block.number, to_block: block.number}
    ])

    state = %{"target_head" => block.number, "last_token_hash" => "0x" <> String.duplicate("f", 40)}

    assert {[:wait], ^state} = ScaledUiBackfill.last_unprocessed_identifiers(state)

    Repo.delete_all(BackfillGap)
    assert {[], ^state} = ScaledUiBackfill.last_unprocessed_identifiers(state)
  end

  test "treats holes between configured block ranges as missing coverage" do
    Application.put_env(:indexer, :block_ranges, "0..9,20..latest")

    assert ScaledUiBackfill.range_missing?(5, 25)
    refute ScaledUiBackfill.range_missing?(20, 25)
  end

  defp insert_transfer(token, block, transaction, from_address, to_address, log_index) do
    insert(:token_transfer,
      amount: Decimal.new(2),
      block: block,
      block_number: block.number,
      from_address: from_address,
      log_index: log_index,
      to_address: to_address,
      token_contract_address: token.contract_address,
      token_type: "ERC-20",
      transaction: transaction,
      ui_amount_status: nil,
      ui_multiplier: nil,
      ui_value: nil
    )
  end

  defp insert_multiplier_log(token, block, transaction, index, multiplier) do
    insert(:log,
      address: token.contract_address,
      block: block,
      block_number: block.number,
      data: uint_data([0, String.to_integer(multiplier), DateTime.to_unix(block.timestamp)]),
      first_topic: topic(Events.ui_multiplier_updated_topic()),
      index: index,
      transaction: transaction
    )
  end

  defp insert_ui_log(token, block, transaction, from_address, to_address, index, amount, ui_value) do
    insert(:log,
      address: token.contract_address,
      block: block,
      block_number: block.number,
      data: uint_data([amount, ui_value]),
      first_topic: topic(Events.transfer_with_ui_amount_topic()),
      index: index,
      second_topic: address_topic(from_address.hash),
      third_topic: address_topic(to_address.hash),
      transaction: transaction
    )
  end

  defp reload(transfer) do
    Repo.get_by!(TokenTransfer,
      transaction_hash: transfer.transaction_hash,
      block_hash: transfer.block_hash,
      log_index: transfer.log_index
    )
  end

  defp topic(value) do
    {:ok, topic} = Hash.Full.cast(value)
    topic
  end

  defp address_topic(address_hash) do
    address_hash
    |> to_string()
    |> String.trim_leading("0x")
    |> String.pad_leading(64, "0")
    |> then(&topic("0x" <> &1))
  end

  defp uint_data(values) do
    "0x" <> Enum.map_join(values, &(&1 |> Integer.to_string(16) |> String.pad_leading(64, "0")))
  end
end
