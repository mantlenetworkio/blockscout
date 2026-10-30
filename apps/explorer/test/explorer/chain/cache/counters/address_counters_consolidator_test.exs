# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Cache.Counters.AddressCountersConsolidatorTest do
  use Explorer.DataCase, async: false

  import ExUnit.CaptureLog

  alias Explorer.Chain.Address
  alias Explorer.Chain.Cache.Counters.{AddressCounters, AddressCountersConsolidator, Consolidation}
  alias Explorer.Repo
  alias Explorer.Utility.CountersRefetchBlock

  describe "consolidate_addresses/2" do
    test "incrementally consolidates an address with a watermark" do
      address =
        insert(:address, transactions_count: 7, token_transfers_count: 2, gas_used: 10, counters_updated_at: 100)

      in_range_block = insert(:block, number: 150)
      above_range_block = insert(:block, number: 300)

      in_range_transaction = :transaction |> insert(from_address: address) |> with_block(in_range_block)
      :transaction |> insert(to_address: address) |> with_block(above_range_block)

      another_transaction = :transaction |> insert() |> with_block(in_range_block)

      insert(:token_transfer,
        from_address: address,
        transaction: another_transaction,
        block: in_range_block,
        block_number: in_range_block.number
      )

      AddressCountersConsolidator.consolidate_addresses([address.hash], 200)

      reloaded = Repo.get(Address, address.hash)

      assert reloaded.transactions_count == 8
      assert reloaded.token_transfers_count == 3
      assert reloaded.gas_used == 10 + Decimal.to_integer(in_range_transaction.gas_used)
      assert reloaded.counters_updated_at == 200
    end

    test "recalculates an address without a watermark from scratch, replacing stale values" do
      address = insert(:address, transactions_count: 1000, token_transfers_count: 1000, gas_used: 1000)

      block = insert(:block, number: 50)
      transaction = :transaction |> insert(from_address: address) |> with_block(block)

      AddressCountersConsolidator.consolidate_addresses([address.hash], 200)

      reloaded = Repo.get(Address, address.hash)

      assert reloaded.transactions_count == 1
      assert reloaded.token_transfers_count == 0
      assert reloaded.gas_used == Decimal.to_integer(transaction.gas_used)
      assert reloaded.counters_updated_at == 200
    end

    test "skips addresses already consolidated at or above the safe block" do
      address = insert(:address, transactions_count: 7, counters_updated_at: 300)

      block = insert(:block, number: 150)
      :transaction |> insert(from_address: address) |> with_block(block)

      AddressCountersConsolidator.consolidate_addresses([address.hash], 200)

      reloaded = Repo.get(Address, address.hash)

      assert reloaded.transactions_count == 7
      assert reloaded.counters_updated_at == 300
    end

    test "accumulates incoming gas for contracts and outgoing gas for EOAs with delegated code" do
      contract = insert(:contract_address, counters_updated_at: 100)

      eoa_with_code =
        insert(:address,
          contract_code: "0xef01001111111111111111111111111111111111111111",
          counters_updated_at: 100
        )

      block = insert(:block, number: 150)

      incoming_to_contract = :transaction |> insert(to_address: contract) |> with_block(block)
      :transaction |> insert(from_address: contract) |> with_block(insert(:block, number: 151))

      incoming_to_eoa = :transaction |> insert(to_address: eoa_with_code) |> with_block(insert(:block, number: 152))
      outgoing_from_eoa = :transaction |> insert(from_address: eoa_with_code) |> with_block(insert(:block, number: 153))

      _ = incoming_to_eoa

      AddressCountersConsolidator.consolidate_addresses([contract.hash, eoa_with_code.hash], 200)

      assert Repo.get(Address, contract.hash).gas_used == Decimal.to_integer(incoming_to_contract.gas_used)
      assert Repo.get(Address, eoa_with_code.hash).gas_used == Decimal.to_integer(outgoing_from_eoa.gas_used)
    end
  end

  describe "safe_block/0" do
    setup do
      initial_env = Application.get_env(:explorer, Consolidation) || []

      Application.put_env(
        :explorer,
        Consolidation,
        Keyword.merge(initial_env, safe_block_lag: 0)
      )

      on_exit(fn -> Application.put_env(:explorer, Consolidation, initial_env) end)

      :ok
    end

    test "returns the lagged chain head" do
      insert(:block, number: 0)
      insert(:block, number: 100)

      assert AddressCountersConsolidator.safe_block() == 100
    end

    test "is nil while the chain is not indexed down to the first block" do
      insert(:block, number: 100)

      assert AddressCountersConsolidator.safe_block() == nil
    end

    test "is capped below the lowest missing block range" do
      insert(:block, number: 0)
      insert(:block, number: 100)
      insert(:missing_block_range, from_number: 60, to_number: 50)

      assert AddressCountersConsolidator.safe_block() == 49
    end

    test "is capped below the lowest block pending a re-fetch counter correction" do
      insert(:block, number: 0)
      insert(:block, number: 100)
      Repo.insert!(%CountersRefetchBlock{block_number: 30})

      assert AddressCountersConsolidator.safe_block() == 29
    end
  end

  describe "consolidation cycle process" do
    test "the process stays responsive while a cycle runs and reports it in its state" do
      pid = start_supervised!(AddressCountersConsolidator)

      send(pid, :consolidate)

      # the cycle runs in a task, so the process answers immediately
      assert %{cycle_task: _, cycle_started_at: _, last_cycle_finished_at: _} = :sys.get_state(pid, 1_000)

      wait_for_results(fn ->
        case :sys.get_state(pid, 1_000) do
          %{cycle_task: nil, last_cycle_finished_at: %DateTime{}} -> :ok
          _ -> raise Ecto.NoResultsError, queryable: "cycle completion"
        end
      end)
    end
  end

  describe "consolidate/0" do
    setup do
      initial_env = Application.get_env(:explorer, Consolidation) || []

      Application.put_env(
        :explorer,
        Consolidation,
        Keyword.merge(initial_env, safe_block_lag: 0)
      )

      on_exit(fn -> Application.put_env(:explorer, Consolidation, initial_env) end)

      start_supervised!(AddressCounters)

      :ok
    end

    test "consolidates dirty addresses and clears their markers" do
      address = insert(:address, transactions_count: 1, token_transfers_count: 0, gas_used: 0, counters_updated_at: 10)

      insert(:block, number: 0)
      block = insert(:block, number: 100)
      :transaction |> insert(from_address: address) |> with_block(block)

      AddressCounters.mark_dirty([{address.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      AddressCountersConsolidator.consolidate()

      reloaded = Repo.get(Address, address.hash)

      assert reloaded.transactions_count == 2
      assert reloaded.counters_updated_at == 100
      assert AddressCounters.dirty_empty?()
    end

    test "keeps markers above the safe block" do
      address = insert(:address, transactions_count: 1, token_transfers_count: 0, gas_used: 0, counters_updated_at: 10)

      insert(:block, number: 0)
      insert(:block, number: 100)

      AddressCounters.mark_dirty([{address.hash.bytes, 500}])
      :sys.get_state(AddressCounters)

      AddressCountersConsolidator.consolidate()

      assert Repo.get(Address, address.hash).counters_updated_at == 100
      refute AddressCounters.dirty_empty?()
    end

    test "settles re-fetched blocks: adds the re-imported content below the watermark and drops the queue rows" do
      address = insert(:address, transactions_count: 5, token_transfers_count: 0, gas_used: 0, counters_updated_at: 100)

      reimported_block = insert(:block, number: 50, refetch_needed: false)
      transaction = :transaction |> insert(from_address: address) |> with_block(reimported_block)

      insert(:block, number: 100)
      Repo.insert!(%CountersRefetchBlock{block_number: 50})

      AddressCountersConsolidator.consolidate()

      reloaded = Repo.get(Address, address.hash)

      assert reloaded.transactions_count == 6
      assert reloaded.gas_used == Decimal.to_integer(transaction.gas_used)
      # settling a covered block does not move the watermark
      assert reloaded.counters_updated_at == 100
      assert Repo.aggregate(CountersRefetchBlock, :count) == 0
    end

    test "does not settle blocks still awaiting their re-fetch" do
      insert(:block, number: 50, refetch_needed: true)
      insert(:block, number: 100)
      Repo.insert!(%CountersRefetchBlock{block_number: 50})

      AddressCountersConsolidator.consolidate()

      assert Repo.aggregate(CountersRefetchBlock, :count) == 1
    end

    test "does not settle blocks still covered by a missing range" do
      # refetch_needed already flipped, but the re-import has not fully
      # completed yet (the missing range row is only removed afterwards);
      # missing ranges are stored descending: from_number is the high end
      insert(:block, number: 50, refetch_needed: false)
      insert(:block, number: 100)
      insert(:missing_block_range, from_number: 60, to_number: 40)
      Repo.insert!(%CountersRefetchBlock{block_number: 50})

      AddressCountersConsolidator.consolidate()

      assert Repo.aggregate(CountersRefetchBlock, :count) == 1
    end
  end

  describe "consolidation in block range steps" do
    setup do
      initial_env = Application.get_env(:explorer, AddressCountersConsolidator) || []
      initial_consolidation_env = Application.get_env(:explorer, Consolidation) || []

      # a step covers at most 2 rows of each row source, and a spent time budget leaves a chunk after one step
      Application.put_env(
        :explorer,
        AddressCountersConsolidator,
        Keyword.merge(initial_env, step_rows: 2, step_time_budget: 0)
      )

      Application.put_env(:explorer, Consolidation, Keyword.merge(initial_consolidation_env, safe_block_lag: 0))

      on_exit(fn ->
        Application.put_env(:explorer, AddressCountersConsolidator, initial_env)
        Application.put_env(:explorer, Consolidation, initial_consolidation_env)
      end)

      start_supervised!(AddressCounters)

      :ok
    end

    test "consolidates an address with more rows than a step covers over several cycles, storing every step" do
      address = insert(:address, transactions_count: 1000, token_transfers_count: 1000, gas_used: 1000)

      insert(:block, number: 0)

      transactions =
        for number <- [10, 20, 30, 40, 50] do
          :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
        end

      insert(:block, number: 100)

      gas_of_first = fn count ->
        transactions |> Enum.take(count) |> Enum.map(&Decimal.to_integer(&1.gas_used)) |> Enum.sum()
      end

      AddressCounters.mark_dirty([{address.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      AddressCountersConsolidator.consolidate()

      # the first step ends at the block of the second row and replaces the stale values
      reloaded = Repo.get(Address, address.hash)
      assert %{transactions_count: 2, token_transfers_count: 0, counters_updated_at: 20} = reloaded
      assert reloaded.gas_used == gas_of_first.(2)

      AddressCountersConsolidator.consolidate()

      assert %{transactions_count: 4, counters_updated_at: 40} = Repo.get(Address, address.hash)

      # fewer rows than a step covers are left, so the last step reaches the safe block
      AddressCountersConsolidator.consolidate()

      reloaded = Repo.get(Address, address.hash)
      assert %{transactions_count: 5, counters_updated_at: 100} = reloaded
      assert reloaded.gas_used == gas_of_first.(5)
      assert AddressCounters.dirty_empty?()
    end

    test "ends a step at the token transfers of the address too" do
      address = insert(:address)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        block = insert(:block, number: number)
        transaction = :transaction |> insert() |> with_block(block)

        insert(:token_transfer,
          to_address: address,
          transaction: transaction,
          block: block,
          block_number: number
        )
      end

      insert(:block, number: 100)

      AddressCounters.mark_dirty([{address.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      AddressCountersConsolidator.consolidate()

      assert %{transactions_count: 0, token_transfers_count: 2, counters_updated_at: 20} =
               Repo.get(Address, address.hash)
    end

    test "stores the steps of the backfill once, at the safe block, so that a failure leaves the address to its retries" do
      address = insert(:address, transactions_count: 1000)

      insert(:block, number: 0)

      for number <- [10, 20, 30, 40, 50] do
        :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
      end

      insert(:block, number: 100)

      test_pid = self()
      handler_id = {__MODULE__, :counters_writes}

      :telemetry.attach(
        handler_id,
        [:explorer, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if String.starts_with?(query, ~s(UPDATE "addresses")), do: send(test_pid, :counters_write)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      AddressCountersConsolidator.consolidate_addresses([address.hash], 100)

      assert %{transactions_count: 5, counters_updated_at: 100} = Repo.get(Address, address.hash)
      assert_received :counters_write
      refute_received :counters_write
    end

    test "reports a cycle that leaves an address part-way" do
      address = insert(:address)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
      end

      insert(:block, number: 100)

      AddressCounters.mark_dirty([{address.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      assert AddressCountersConsolidator.consolidate() == :catching_up
      assert AddressCountersConsolidator.consolidate() == :ok
      assert %{counters_updated_at: 100} = Repo.get(Address, address.hash)
    end

    test "keeps the regular interval after a failed step, even if the budget left another address part-way" do
      addresses = insert_list(2, :address)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        block = insert(:block, number: number)

        Enum.each(addresses, fn address ->
          :transaction |> insert(from_address: address) |> with_block(block)
        end)
      end

      insert(:block, number: 100)

      # no counters update is stored (rolled back with the test): the step
      # taken fails as if its watermark had moved, the other address waits
      Repo.query!("CREATE FUNCTION test_skip_update() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NULL; END'")

      Repo.query!(
        "CREATE TRIGGER test_skip_address_updates BEFORE UPDATE ON addresses FOR EACH ROW EXECUTE FUNCTION test_skip_update()"
      )

      AddressCounters.mark_dirty(Enum.map(addresses, &{&1.hash.bytes, 100}))
      :sys.get_state(AddressCounters)

      assert AddressCountersConsolidator.consolidate() == :ok
    end

    test "keeps the regular interval after a rejected write of an address consolidated whole" do
      light = insert(:address)
      heavy = insert(:address)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        :transaction |> insert(from_address: heavy) |> with_block(insert(:block, number: number))
      end

      :transaction |> insert(from_address: light) |> with_block(insert(:block, number: 40))
      insert(:block, number: 100)

      # the counters of the light address are not stored, as if a reorg had
      # reset its watermark meanwhile (rolled back with the test)
      Repo.query!("CREATE FUNCTION test_skip_update() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NULL; END'")

      Repo.query!("""
      CREATE TRIGGER test_skip_light_update BEFORE UPDATE ON addresses FOR EACH ROW
      WHEN (OLD.hash = '\\x#{Base.encode16(light.hash.bytes, case: :lower)}'::bytea) EXECUTE FUNCTION test_skip_update()
      """)

      AddressCounters.mark_dirty([{light.hash.bytes, 100}, {heavy.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      assert AddressCountersConsolidator.consolidate() == :ok

      # the heavy address still took its step
      assert %{counters_updated_at: 20} = Repo.get(Address, heavy.hash)
      assert is_nil(Repo.get(Address, light.hash).counters_updated_at)
    end

    test "keeps the regular interval after a failed settlement of re-fetched blocks" do
      address = insert(:address)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
      end

      insert(:block, number: 50, refetch_needed: false)
      insert(:block, number: 100)
      Repo.insert!(%CountersRefetchBlock{block_number: 50})

      # the settlement cannot drop its queue row (rolled back with the test)
      Repo.query!(
        "CREATE FUNCTION test_fail() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''failed''; END'"
      )

      Repo.query!(
        "CREATE TRIGGER test_fail_settlement BEFORE DELETE ON counters_refetch_blocks FOR EACH ROW EXECUTE FUNCTION test_fail()"
      )

      AddressCounters.mark_dirty([{address.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      assert capture_log(fn -> assert AddressCountersConsolidator.consolidate() == :ok end) =~
               "Failed to settle re-fetched blocks counters"

      # the address still took its step, below the pending re-fetch
      assert %{counters_updated_at: 20} = Repo.get(Address, address.hash)
    end

    test "starts the next cycle after a short pause while an address catches up, after the interval otherwise" do
      initial_env = Application.get_env(:explorer, AddressCountersConsolidator)

      Application.put_env(
        :explorer,
        AddressCountersConsolidator,
        Keyword.merge(initial_env, interval: :timer.hours(1), catch_up_pause: 10)
      )

      address = insert(:address)

      insert(:block, number: 0)

      for number <- [10, 20, 30, 40, 50] do
        :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
      end

      insert(:block, number: 100)

      AddressCounters.mark_dirty([{address.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      pid = start_supervised!(AddressCountersConsolidator)
      send(pid, :consolidate)

      # three cycles: 20, 40, then the safe block
      wait_for_results(fn ->
        case Repo.get(Address, address.hash) do
          %{counters_updated_at: 100} -> :ok
          _ -> raise Ecto.NoResultsError, queryable: "catch-up"
        end
      end)

      wait_for_results(fn ->
        case :sys.get_state(pid) do
          %{cycle_task: nil, last_cycle_finished_at: %DateTime{}} = state -> state
          _ -> raise Ecto.NoResultsError, queryable: "cycle completion"
        end
      end)

      %{last_cycle_finished_at: finished_at} = :sys.get_state(pid)

      # caught up: the next cycle waits for the regular interval
      Process.sleep(200)

      assert %{cycle_task: nil, last_cycle_finished_at: ^finished_at} = :sys.get_state(pid)
    end

    test "keeps the dirty marker of a contract until its steps reach the safe block" do
      contract = insert(:contract_address)

      insert(:block, number: 0)

      incoming =
        for number <- [10, 20, 30] do
          :transaction |> insert(to_address: contract) |> with_block(insert(:block, number: number))
        end

      insert(:block, number: 100)

      AddressCounters.mark_dirty([{contract.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      AddressCountersConsolidator.consolidate()

      assert %{transactions_count: 2, counters_updated_at: 20} = Repo.get(Address, contract.hash)
      refute AddressCounters.dirty_empty?()

      AddressCountersConsolidator.consolidate()

      reloaded = Repo.get(Address, contract.hash)
      assert %{transactions_count: 3, counters_updated_at: 100} = reloaded
      # incoming gas for contracts
      assert reloaded.gas_used == incoming |> Enum.map(&Decimal.to_integer(&1.gas_used)) |> Enum.sum()
      assert AddressCounters.dirty_empty?()
    end

    test "leaves the other stepped addresses of a chunk to the next cycle once the time budget is spent" do
      addresses = insert_list(2, :address)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        block = insert(:block, number: number)

        Enum.each(addresses, fn address ->
          :transaction |> insert(from_address: address) |> with_block(block)
        end)
      end

      insert(:block, number: 100)

      AddressCounters.mark_dirty(Enum.map(addresses, &{&1.hash.bytes, 100}))
      :sys.get_state(AddressCounters)

      watermarks = fn ->
        addresses |> Enum.map(&Repo.get(Address, &1.hash).counters_updated_at) |> Enum.sort()
      end

      AddressCountersConsolidator.consolidate()

      assert watermarks.() == [20, nil]

      # the address with one row left finishes in one go, the other one takes its first step
      AddressCountersConsolidator.consolidate()

      assert watermarks.() == [20, 100]

      AddressCountersConsolidator.consolidate()

      assert watermarks.() == [100, 100]
      assert Enum.all?(addresses, &(Repo.get(Address, &1.hash).transactions_count == 3))
      assert AddressCounters.dirty_empty?()
    end

    test "takes an address too large for one step to the safe block when called by the backfill" do
      # a full dirty markers table: nothing could be handed over to the cycles
      initial_counters_env = Application.get_env(:explorer, AddressCounters) || []
      Application.put_env(:explorer, AddressCounters, Keyword.merge(initial_counters_env, max_dirty_markers: 0))
      on_exit(fn -> Application.put_env(:explorer, AddressCounters, initial_counters_env) end)

      address = insert(:address, transactions_count: 1000)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
      end

      insert(:block, number: 100)

      # in steps, and without the time budget of the cycles
      AddressCountersConsolidator.consolidate_addresses([address.hash], 100)

      assert %{transactions_count: 3, counters_updated_at: 100} = Repo.get(Address, address.hash)
    end

    test "keeps the dirty marker of an address whose cycle crashes after a step" do
      address = insert(:address)

      insert(:block, number: 0)

      for number <- [10, 20, 30] do
        :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
      end

      insert(:block, number: 100)

      AddressCounters.mark_dirty([{address.hash.bytes, 100}])
      :sys.get_state(AddressCounters)

      cycle = spawn(fn -> receive do: (:go -> AddressCountersConsolidator.consolidate()) end)
      ref = Process.monitor(cycle)

      handler_id = {__MODULE__, :crash_after_first_step}

      # kills the task of the cycle right after its first counters write, which
      # takes the linked cycle down with it
      :telemetry.attach(
        handler_id,
        [:explorer, :repo, :query],
        fn _event, _measurements, %{query: query}, cycle ->
          if cycle in Process.get(:"$callers", []) and String.starts_with?(query, ~s(UPDATE "addresses")) do
            Process.exit(self(), :kill)
          end
        end,
        cycle
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      send(cycle, :go)

      assert_receive {:DOWN, ^ref, :process, ^cycle, :killed}, 10_000
      assert %{counters_updated_at: 20} = Repo.get(Address, address.hash)
      refute AddressCounters.dirty_empty?()

      AddressCountersConsolidator.consolidate()

      assert %{transactions_count: 3, counters_updated_at: 100} = Repo.get(Address, address.hash)
    end

    test "does not fall back to whole-history aggregates when the step of an address cannot be found" do
      # a negative OFFSET makes every step probe fail
      Application.put_env(
        :explorer,
        AddressCountersConsolidator,
        Keyword.merge(Application.get_env(:explorer, AddressCountersConsolidator), step_rows: 0)
      )

      address = insert(:address)

      for number <- [10, 20, 30] do
        :transaction |> insert(from_address: address) |> with_block(insert(:block, number: number))
      end

      assert capture_log(fn -> AddressCountersConsolidator.consolidate_addresses([address.hash], 200) end) =~
               "Failed to find the consolidation step of address"

      assert is_nil(Repo.get(Address, address.hash).counters_updated_at)

      # left to a later cycle
      :sys.get_state(AddressCounters)
      assert {[{marked_bytes, _block_number}], _continuation} = AddressCounters.select_dirty(10)
      assert marked_bytes == address.hash.bytes
    end
  end

  describe "reset_covered_watermarks/2" do
    test "resets only addresses whose watermark covers the block and marks them dirty" do
      start_supervised!(AddressCounters)

      covered_address = insert(:address, counters_updated_at: 100)
      # covers the lowest given block, but not its own one
      fresh_address = insert(:address, counters_updated_at: 60)

      reset_bytes =
        AddressCountersConsolidator.reset_covered_watermarks(%{
          covered_address.hash.bytes => 50,
          fresh_address.hash.bytes => 70
        })

      assert reset_bytes == [covered_address.hash.bytes]
      assert is_nil(Repo.get(Address, covered_address.hash).counters_updated_at)
      assert Repo.get(Address, fresh_address.hash).counters_updated_at == 60

      # the recalculation of the reset address is scheduled
      :sys.get_state(AddressCounters)
      assert {[{marked_bytes, _block_number}], _continuation} = AddressCounters.select_dirty(10)
      assert marked_bytes == covered_address.hash.bytes
    end
  end

  describe "apply_covered_deltas/4" do
    test "applies negative deltas only for blocks covered by the address watermark" do
      address =
        insert(:address, transactions_count: 5, token_transfers_count: 3, gas_used: 100, counters_updated_at: 100)

      transactions = [
        %{block_number: 50, from_address_hash: address.hash, to_address_hash: nil, gas_used: 30},
        # above the watermark: never counted, must not be subtracted
        %{block_number: 150, from_address_hash: address.hash, to_address_hash: nil, gas_used: 30}
      ]

      token_transfers = [
        %{block_number: 50, from_address_hash: address.hash, to_address_hash: nil}
      ]

      [updated_bytes] = AddressCountersConsolidator.apply_covered_deltas(transactions, token_transfers, :negative)

      assert updated_bytes == address.hash.bytes

      reloaded = Repo.get(Address, address.hash)

      assert reloaded.transactions_count == 4
      assert reloaded.token_transfers_count == 2
      assert reloaded.gas_used == 70
      assert reloaded.counters_updated_at == 100
    end

    test "skips addresses without a watermark" do
      address = insert(:address, transactions_count: 5)

      transactions = [%{block_number: 50, from_address_hash: address.hash, to_address_hash: nil, gas_used: 30}]

      assert AddressCountersConsolidator.apply_covered_deltas(transactions, [], :positive) == []
      assert Repo.get(Address, address.hash).transactions_count == 5
    end
  end
end
