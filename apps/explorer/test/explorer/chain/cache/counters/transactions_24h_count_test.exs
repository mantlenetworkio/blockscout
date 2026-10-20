defmodule Explorer.Chain.Cache.Counters.Transactions24hCountTest do
  use Explorer.DataCase

  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.Cache.Counters.Transactions24hCount

  test "populates the cache with transaction counters" do
    block = insert(:block, base_fee_per_gas: 50)
    address = insert(:address)

    # fee = 10000

    insert(:transaction,
      from_address: address,
      block: block,
      block_number: block.number,
      cumulative_gas_used: 0,
      index: 0,
      gas_price: 100,
      gas_used: 100
    )

    # fee = 15000

    insert(:transaction,
      from_address: address,
      block: block,
      block_number: block.number,
      cumulative_gas_used: 100,
      index: 1,
      gas_price: 150,
      gas_used: 100,
      max_priority_fee_per_gas: 100,
      max_fee_per_gas: 200
    )

    # fee = 10000

    insert(:transaction,
      from_address: address,
      block: block,
      block_number: block.number,
      cumulative_gas_used: 200,
      index: 2,
      gas_price: 100,
      gas_used: 100,
      max_priority_fee_per_gas: 70,
      max_fee_per_gas: 100
    )

    start_supervised!(Transactions24hCount)
    Transactions24hCount.consolidate()

    transactions_count = Transactions24hCount.fetch_count([])
    transaction_fee_sum = Transactions24hCount.fetch_fee_sum([])
    transaction_fee_average = Transactions24hCount.fetch_fee_average([])

    assert transactions_count == Decimal.new("3")
    assert transaction_fee_sum == Decimal.new("35000")
    assert transaction_fee_average == Decimal.new("11667")
  end

  describe "once transactions carry their block timestamp" do
    setup do
      BackgroundMigrations.set_transactions_denormalization_finished(true)
      on_exit(fn -> BackgroundMigrations.set_transactions_denormalization_finished(false) end)
    end

    test "takes the fee of a transaction without a gas price from its block's base fee" do
      block = insert(:block, base_fee_per_gas: 50)
      address = insert(:address)

      # fee = 100 * 100
      insert(:transaction,
        from_address: address,
        block: block,
        block_number: block.number,
        block_timestamp: block.timestamp,
        cumulative_gas_used: 0,
        index: 0,
        gas_price: 100,
        gas_used: 100
      )

      # fee = (50 + min(30, 100 - 50)) * 100
      insert(:transaction,
        from_address: address,
        block: block,
        block_number: block.number,
        block_timestamp: block.timestamp,
        cumulative_gas_used: 100,
        index: 1,
        gas_price: nil,
        gas_used: 100,
        max_priority_fee_per_gas: 30,
        max_fee_per_gas: 100
      )

      Transactions24hCount.consolidate()

      assert Transactions24hCount.fetch_count([]) == Decimal.new("2")
      assert Transactions24hCount.fetch_fee_sum([]) == Decimal.new("18000")
      assert Transactions24hCount.fetch_fee_average([]) == Decimal.new("9000")
    end

    # Joined, every transaction of the day looked its block up by hash, one random read each (~43k blocks a day on a
    # 2 s chain, minutes on a busy database); a mined transaction has a gas price, so the block is rarely needed.
    test "looks the block up only in the fallback of COALESCE, for a transaction without a gas price" do
      test = self()

      :telemetry.attach(
        "transactions-24h-count-query",
        [:explorer, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if query =~ "block_timestamp", do: send(test, {:count_query, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("transactions-24h-count-query") end)

      Transactions24hCount.consolidate()
      assert_received {:count_query, query}

      refute query =~ ~r/JOIN "blocks"/
      assert query =~ ~r/COALESCE\(t0\."gas_price", \(SELECT b\.base_fee_per_gas/
    end
  end
end
