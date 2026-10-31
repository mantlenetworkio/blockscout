# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Metrics.Queries.IndexerMetricsTest do
  use Explorer.DataCase, async: false

  import Explorer.Factory

  alias Explorer.Chain.Metrics.Queries.IndexerMetrics
  alias Explorer.Chain.ScaledUi.TokenState
  alias Explorer.Repo

  describe "scaled_ui_inventory/0" do
    test "counts only canonical unresolved transfers and tainted token states" do
      token = insert(:token)
      block = insert(:block)
      from_address = insert(:address)
      to_address = insert(:address)

      Enum.each(Enum.with_index(["unknown", "mismatch", "event_missing", "ok"]), fn {status, log_index} ->
        transaction = insert(:transaction) |> with_block(block)

        insert(:token_transfer,
          block: block,
          block_consensus: true,
          block_number: block.number,
          from_address: from_address,
          log_index: log_index,
          to_address: to_address,
          token_contract_address: token.contract_address,
          transaction: transaction,
          ui_amount_status: status
        )
      end)

      orphan_transaction = insert(:transaction) |> with_block(block)

      insert(:token_transfer,
        block: block,
        block_consensus: false,
        block_number: block.number,
        from_address: from_address,
        log_index: 10,
        to_address: to_address,
        token_contract_address: token.contract_address,
        transaction: orphan_transaction,
        ui_amount_status: "mismatch"
      )

      tainted_address = insert(:address)
      ok_address = insert(:address)

      %TokenState{}
      |> TokenState.changeset(%{
        token_contract_address_hash: tainted_address.hash,
        timeline_status: "tainted",
        tainted_from_block: 10
      })
      |> Repo.insert!()

      %TokenState{}
      |> TokenState.changeset(%{
        token_contract_address_hash: ok_address.hash,
        timeline_status: "ok"
      })
      |> Repo.insert!()

      assert IndexerMetrics.scaled_ui_inventory() == %{
               token_transfers: %{"event_missing" => 1, "mismatch" => 1, "unknown" => 1},
               tainted_tokens: 1
             }
    end
  end

  describe "blocks_realtime_indexing_delay_percentiles/0" do
    test "measures the indexing delay of the consensus blocks of the last 5 minutes" do
      now = DateTime.utc_now()

      insert(:block,
        consensus: true,
        timestamp: DateTime.add(now, -60, :second),
        inserted_at: DateTime.add(now, -58, :second)
      )

      # a non-consensus block and a block older than the window do not count
      insert(:block,
        consensus: false,
        timestamp: DateTime.add(now, -60, :second),
        inserted_at: DateTime.add(now, -30, :second)
      )

      insert(:block,
        consensus: true,
        timestamp: DateTime.add(now, -600, :second),
        inserted_at: DateTime.add(now, -500, :second)
      )

      # the session's TimeZone must not move the window
      for time_zone <- ["UTC", "Asia/Shanghai"] do
        Repo.query!("SET LOCAL TIME ZONE '#{time_zone}'")
        percentiles = IndexerMetrics.blocks_realtime_indexing_delay_percentiles()

        assert percentiles["p50"] == 2_000_000_000
        assert percentiles["p99"] == 2_000_000_000
      end
    end

    test "reads the window of recent blocks through the timestamp index" do
      # as on a live chain, nearly all blocks are older than the window
      miner = insert(:address)
      insert_list(1_000, :block, miner: miner, timestamp: DateTime.add(DateTime.utc_now(), -86_400, :second))
      insert(:block, miner: miner)
      Repo.query!("ANALYZE blocks")

      test_pid = self()
      handler_id = {__MODULE__, :blocks_delay_query}

      :telemetry.attach(
        handler_id,
        [:explorer, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if query =~ "delay_nanoseconds", do: send(test_pid, {:delay_query, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      IndexerMetrics.blocks_realtime_indexing_delay_percentiles()
      assert_received {:delay_query, query}

      # the test table is tiny, so the planner would scan it whatever the filter
      Repo.query!("SET LOCAL enable_seqscan = off")
      %{rows: rows} = Repo.query!("EXPLAIN " <> query)

      assert Enum.any?(rows, fn [line] -> line =~ "blocks_timestamp_index" end)
    end
  end

  describe "missing_blocks_count/0" do
    test "counts only within configured ranges and latest tail" do
      previous_block_ranges = Application.get_env(:indexer, :block_ranges)
      on_exit(fn -> Application.put_env(:indexer, :block_ranges, previous_block_ranges) end)

      Application.put_env(:indexer, :block_ranges, "1..3,5..latest")

      Enum.each([1, 2, 3, 5, 7, 8], fn number ->
        insert(:block, number: number, consensus: true)
      end)

      assert IndexerMetrics.missing_blocks_count() == 1
    end

    test "counts only within finite ranges" do
      previous_block_ranges = Application.get_env(:indexer, :block_ranges)
      on_exit(fn -> Application.put_env(:indexer, :block_ranges, previous_block_ranges) end)

      Application.put_env(:indexer, :block_ranges, "10..12,20..22")

      Enum.each([10, 11, 12, 20, 22], fn number ->
        insert(:block, number: number, consensus: true)
      end)

      assert IndexerMetrics.missing_blocks_count() == 1
    end
  end

  describe "refetch_needed_blocks_count/0" do
    test "counts only consensus blocks marked for refetch within configured ranges and latest tail" do
      previous_block_ranges = Application.get_env(:indexer, :block_ranges)
      on_exit(fn -> Application.put_env(:indexer, :block_ranges, previous_block_ranges) end)

      Application.put_env(:indexer, :block_ranges, "1..3,5..latest")

      # within ranges, consensus and refetch_needed -> counted
      insert(:block, number: 1, consensus: true, refetch_needed: true)
      insert(:block, number: 7, consensus: true, refetch_needed: true)
      # within ranges but not marked -> not counted
      insert(:block, number: 2, consensus: true, refetch_needed: false)
      # marked but not consensus -> not counted
      insert(:block, number: 3, consensus: false, refetch_needed: true)
      # marked and consensus but outside the ranges -> not counted
      insert(:block, number: 4, consensus: true, refetch_needed: true)

      assert IndexerMetrics.refetch_needed_blocks_count() == 2
    end

    test "counts only within finite ranges" do
      previous_block_ranges = Application.get_env(:indexer, :block_ranges)
      on_exit(fn -> Application.put_env(:indexer, :block_ranges, previous_block_ranges) end)

      Application.put_env(:indexer, :block_ranges, "10..12,20..22")

      insert(:block, number: 11, consensus: true, refetch_needed: true)
      insert(:block, number: 21, consensus: true, refetch_needed: true)
      # outside the finite ranges -> not counted
      insert(:block, number: 30, consensus: true, refetch_needed: true)

      assert IndexerMetrics.refetch_needed_blocks_count() == 2
    end
  end

  describe "missing_internal_transactions_count/0" do
    test "counts pending block operations when pending_operations_type is blocks" do
      previous_explorer_config = Application.get_env(:explorer, :json_rpc_named_arguments)
      previous_geth_config = Application.get_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth)
      previous_trace_first_block = Application.get_env(:indexer, :trace_first_block)

      on_exit(fn ->
        Application.put_env(:explorer, :json_rpc_named_arguments, previous_explorer_config)
        Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, previous_geth_config)
        Application.put_env(:indexer, :trace_first_block, previous_trace_first_block)
      end)

      # Set configuration to use "blocks" mode (non-Geth or Geth with block_traceable)
      Application.put_env(:explorer, :json_rpc_named_arguments, variant: EthereumJSONRPC.Nethermind)

      block1 = insert(:block)
      block2 = insert(:block)
      block3 = insert(:block)

      insert(:pending_block_operation, block_hash: block1.hash, block_number: block1.number)
      insert(:pending_block_operation, block_hash: block2.hash, block_number: block2.number)
      insert(:pending_block_operation, block_hash: block3.hash, block_number: block3.number)

      assert IndexerMetrics.missing_internal_transactions_count() == 3
    end

    test "respects trace_first_block when counting pending block operations" do
      previous_explorer_config = Application.get_env(:explorer, :json_rpc_named_arguments)
      previous_geth_config = Application.get_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth)
      previous_trace_first_block = Application.get_env(:indexer, :trace_first_block)

      on_exit(fn ->
        Application.put_env(:explorer, :json_rpc_named_arguments, previous_explorer_config)
        Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, previous_geth_config)
        Application.put_env(:indexer, :trace_first_block, previous_trace_first_block)
      end)

      Application.put_env(:explorer, :json_rpc_named_arguments, variant: EthereumJSONRPC.Nethermind)
      Application.put_env(:indexer, :trace_first_block, 10)

      block1 = insert(:block, number: 8)
      block2 = insert(:block, number: 10)
      block3 = insert(:block, number: 12)

      insert(:pending_block_operation, block_hash: block1.hash, block_number: block1.number)
      insert(:pending_block_operation, block_hash: block2.hash, block_number: block2.number)
      insert(:pending_block_operation, block_hash: block3.hash, block_number: block3.number)

      assert IndexerMetrics.missing_internal_transactions_count() == 2
    end

    test "counts pending transaction operations when pending_operations_type is transactions" do
      previous_explorer_config = Application.get_env(:explorer, :json_rpc_named_arguments)
      previous_geth_config = Application.get_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth)
      previous_trace_first_block = Application.get_env(:indexer, :trace_first_block)

      on_exit(fn ->
        Application.put_env(:explorer, :json_rpc_named_arguments, previous_explorer_config)
        Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, previous_geth_config)
        Application.put_env(:indexer, :trace_first_block, previous_trace_first_block)
      end)

      # Set configuration to use "transactions" mode (Geth with block_traceable? = false)
      Application.put_env(:explorer, :json_rpc_named_arguments, variant: EthereumJSONRPC.Geth)
      Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, block_traceable?: false)

      transaction1 = insert(:transaction)
      transaction2 = insert(:transaction)

      insert(:pending_transaction_operation, transaction_hash: transaction1.hash)
      insert(:pending_transaction_operation, transaction_hash: transaction2.hash)

      assert IndexerMetrics.missing_internal_transactions_count() == 2
    end
  end

  describe "missing_address_native_coin_balances_count/0" do
    test "counts only unfetched coin balances within configured ranges and latest tail" do
      previous_block_ranges = Application.get_env(:indexer, :block_ranges)
      on_exit(fn -> Application.put_env(:indexer, :block_ranges, previous_block_ranges) end)

      Application.put_env(:indexer, :block_ranges, "1..3,5..latest")

      address = insert(:address)

      # within ranges and unfetched -> counted
      insert(:unfetched_balance, address_hash: address.hash, block_number: 1)
      insert(:unfetched_balance, address_hash: address.hash, block_number: 7)
      # within ranges but fetched -> not counted
      insert(:unfetched_balance,
        address_hash: address.hash,
        block_number: 2,
        value: 100,
        value_fetched_at: DateTime.utc_now()
      )

      # unfetched but outside the ranges -> not counted
      insert(:unfetched_balance, address_hash: address.hash, block_number: 4)

      assert IndexerMetrics.missing_address_native_coin_balances_count() == 2
    end

    test "counts only within finite ranges" do
      previous_block_ranges = Application.get_env(:indexer, :block_ranges)
      on_exit(fn -> Application.put_env(:indexer, :block_ranges, previous_block_ranges) end)

      Application.put_env(:indexer, :block_ranges, "10..12,20..22")

      address = insert(:address)

      insert(:unfetched_balance, address_hash: address.hash, block_number: 11)
      insert(:unfetched_balance, address_hash: address.hash, block_number: 21)
      # outside the finite ranges -> not counted
      insert(:unfetched_balance, address_hash: address.hash, block_number: 30)

      assert IndexerMetrics.missing_address_native_coin_balances_count() == 2
    end
  end

  describe "missing_archival_token_balances_count/0" do
    test "returns 0 when archival token balances fetcher is disabled" do
      previous_config =
        Application.get_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor)

      on_exit(fn ->
        Application.put_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor, previous_config)
      end)

      Application.put_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor, disabled?: true)

      insert(:token_balance, value_fetched_at: nil)
      insert(:token_balance, value_fetched_at: nil)

      assert IndexerMetrics.missing_archival_token_balances_count() == 0
    end

    test "counts token balances with missing values when fetcher is enabled" do
      previous_config =
        Application.get_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor)

      on_exit(fn ->
        Application.put_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor, previous_config)
      end)

      Application.put_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor, disabled?: false)

      insert(:token_balance, value_fetched_at: nil)
      insert(:token_balance, value_fetched_at: nil)
      insert(:token_balance, value_fetched_at: DateTime.utc_now())

      assert IndexerMetrics.missing_archival_token_balances_count() == 2
    end

    test "returns 0 when all token balances are fetched" do
      previous_config =
        Application.get_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor)

      on_exit(fn ->
        Application.put_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor, previous_config)
      end)

      Application.put_env(:indexer, Indexer.Fetcher.TokenBalance.Historical.Supervisor, disabled?: false)

      insert(:token_balance, value_fetched_at: DateTime.utc_now())
      insert(:token_balance, value_fetched_at: DateTime.utc_now())

      assert IndexerMetrics.missing_archival_token_balances_count() == 0
    end
  end

  describe "multichain_search_db_export_balances_queue_count/0" do
    test "returns 0 when multichain search is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, service_url: nil)

      insert(:multichain_search_db_export_balances_queue)
      insert(:multichain_search_db_export_balances_queue)

      assert IndexerMetrics.multichain_search_db_export_balances_queue_count() == 0
    end

    test "returns 0 when balances export queue supervisor is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.BalancesExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.BalancesExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.BalancesExportQueue.Supervisor, disabled?: true)

      insert(:multichain_search_db_export_balances_queue)
      insert(:multichain_search_db_export_balances_queue)

      assert IndexerMetrics.multichain_search_db_export_balances_queue_count() == 0
    end

    test "counts queue entries when both enabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.BalancesExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.BalancesExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.BalancesExportQueue.Supervisor, disabled?: false)

      insert(:multichain_search_db_export_balances_queue)
      insert(:multichain_search_db_export_balances_queue)

      assert IndexerMetrics.multichain_search_db_export_balances_queue_count() == 2
    end
  end

  describe "multichain_search_db_export_counters_queue_count/0" do
    test "returns 0 when multichain search is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, service_url: nil)

      insert(:multichain_search_db_export_counters_queue)

      assert IndexerMetrics.multichain_search_db_export_counters_queue_count() == 0
    end

    test "returns 0 when counters export queue supervisor is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.CountersExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.CountersExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.CountersExportQueue.Supervisor, disabled?: true)

      insert(:multichain_search_db_export_counters_queue)

      assert IndexerMetrics.multichain_search_db_export_counters_queue_count() == 0
    end

    test "counts queue entries when both enabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.CountersExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.CountersExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.CountersExportQueue.Supervisor, disabled?: false)

      insert(:multichain_search_db_export_counters_queue)

      assert IndexerMetrics.multichain_search_db_export_counters_queue_count() == 1
    end
  end

  describe "multichain_search_db_export_token_info_queue_count/0" do
    test "returns 0 when multichain search is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, service_url: nil)

      insert(:multichain_search_db_export_token_info_queue)

      assert IndexerMetrics.multichain_search_db_export_token_info_queue_count() == 0
    end

    test "returns 0 when token info export queue supervisor is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.TokenInfoExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.TokenInfoExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.TokenInfoExportQueue.Supervisor, disabled?: true)

      insert(:multichain_search_db_export_token_info_queue)

      assert IndexerMetrics.multichain_search_db_export_token_info_queue_count() == 0
    end

    test "counts queue entries when both enabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.TokenInfoExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.TokenInfoExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.TokenInfoExportQueue.Supervisor,
        disabled?: false
      )

      insert(:multichain_search_db_export_token_info_queue)

      assert IndexerMetrics.multichain_search_db_export_token_info_queue_count() == 1
    end
  end

  describe "multichain_search_db_main_export_queue_count/0" do
    test "returns 0 when multichain search is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, service_url: nil)

      insert(:multichain_search_db_main_export_queue)

      assert IndexerMetrics.multichain_search_db_main_export_queue_count() == 0
    end

    test "returns 0 when main export queue supervisor is disabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.MainExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.MainExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.MainExportQueue.Supervisor, disabled?: true)

      insert(:multichain_search_db_main_export_queue)

      assert IndexerMetrics.multichain_search_db_main_export_queue_count() == 0
    end

    test "counts queue entries when both enabled" do
      previous_enabled =
        Application.get_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch)

      previous_supervisor_config =
        Application.get_env(:indexer, Indexer.Fetcher.MultichainSearchDb.MainExportQueue.Supervisor)

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch, previous_enabled)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.MultichainSearchDb.MainExportQueue.Supervisor,
          previous_supervisor_config
        )
      end)

      Application.put_env(:explorer, Explorer.MicroserviceInterfaces.MultichainSearch,
        service_url: "http://localhost:8080"
      )

      Application.put_env(:indexer, Indexer.Fetcher.MultichainSearchDb.MainExportQueue.Supervisor, disabled?: false)

      insert(:multichain_search_db_main_export_queue)

      assert IndexerMetrics.multichain_search_db_main_export_queue_count() == 1
    end
  end
end
