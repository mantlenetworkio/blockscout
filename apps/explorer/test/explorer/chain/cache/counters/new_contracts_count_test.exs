# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Cache.Counters.NewContractsCountTest do
  use Explorer.DataCase

  alias Explorer.Chain
  alias Explorer.Chain.Cache.Counters.NewContractsCount

  test "populates the cache with the number of new contracts (last 24h)" do
    :transaction
    |> insert(created_contract_code_indexed_at: Timex.shift(Timex.now(), hours: -1))
    |> with_block(status: :ok)

    :transaction
    |> insert(created_contract_code_indexed_at: Timex.shift(Timex.now(), hours: -25))
    |> with_block(status: :ok)

    :transaction
    |> insert(created_contract_code_indexed_at: Timex.shift(Timex.now(), hours: -23))
    |> with_block(status: :ok)

    :transaction
    |> insert(created_contract_code_indexed_at: Timex.shift(Timex.now(), hours: -30))
    |> with_block(status: :ok)

    start_supervised!(NewContractsCount)
    NewContractsCount.consolidate()

    assert Chain.count_new_contracts_from_cache() == Decimal.new(2)
  end

  # On a chain with 164M transactions the bare comparison reads the index on created_contract_code_indexed_at (plan
  # cost 8.6), while an expression of the column made the count a parallel scan of every transaction (cost 11.4M,
  # 10+ min). Which index the planner picks depends on statistics a test database does not have, so the test pins the
  # comparison.
  test "compares created_contract_code_indexed_at bare, so that the count can read its index" do
    test = self()

    :telemetry.attach(
      "new-contracts-count-query",
      [:explorer, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ "created_contract_code_indexed_at", do: send(test, {:count_query, query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("new-contracts-count-query") end)

    NewContractsCount.consolidate()
    assert_received {:count_query, query}

    assert query =~ ~r/t0\."created_contract_code_indexed_at" >= \$\d+/
  end
end
