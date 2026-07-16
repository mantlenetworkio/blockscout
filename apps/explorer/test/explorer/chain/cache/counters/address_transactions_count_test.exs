defmodule Explorer.Chain.Cache.Counters.AddressTransactionsCountTest do
  use Explorer.DataCase

  import Explorer.Factory

  alias Explorer.Chain
  alias Explorer.Chain.Address.Counters
  alias Explorer.Chain.Cache.Counters.AddressTabsElementsCount
  alias Explorer.Chain.Cache.Counters.AddressTransactionsCount

  describe "invalidate/1" do
    test "drops cached transactions count for an address" do
      address = insert(:address)

      insert(:transaction, from_address: address) |> with_block()

      assert AddressTransactionsCount.fetch(address) == 1

      insert(:transaction, to_address: address) |> with_block()

      assert AddressTransactionsCount.fetch(address) == 1

      AddressTransactionsCount.invalidate(address.hash)

      assert AddressTransactionsCount.fetch(address) == 2
    end
  end

  describe "Chain.import/1" do
    test "invalidates cached transactions count for imported transaction addresses" do
      address = insert(:address)
      to_address = insert(:address)

      insert(:transaction, from_address: address) |> with_block()

      assert AddressTransactionsCount.fetch(address) == 1
      AddressTabsElementsCount.set_counter(:transactions, address.hash, 1)

      block = insert(:block)

      assert {:ok, %{transactions: [_transaction]}} =
               Chain.import(%{
                 transactions: %{
                   params: [
                     params_for(:transaction,
                       hash: build(:transaction).hash,
                       block_hash: block.hash,
                       block_number: block.number,
                       index: 0,
                       from_address_hash: address.hash,
                       to_address_hash: to_address.hash,
                       gas_used: 0,
                       cumulative_gas_used: 0
                     )
                   ]
                 }
               })

      assert AddressTransactionsCount.fetch(address) == 2
      assert AddressTabsElementsCount.get_counter(:transactions, address.hash) == nil
    end

    test "invalidates cached token transfer tab counters for imported transfer addresses" do
      from_address = insert(:address)
      to_address = insert(:address)
      token = insert(:token)
      transaction = insert(:transaction) |> with_block()

      AddressTabsElementsCount.set_counter(:token_transfers, from_address.hash, 1)
      AddressTabsElementsCount.set_counter(:token_transfers, to_address.hash, 1)

      assert {:ok, %{token_transfers: [_token_transfer]}} =
               Chain.import(%{
                 token_transfers: %{
                   params: [
                     params_for(:token_transfer,
                       transaction_hash: transaction.hash,
                       block_hash: transaction.block_hash,
                       block_number: transaction.block_number,
                       from_address_hash: from_address.hash,
                       to_address_hash: to_address.hash,
                       token_contract_address_hash: token.contract_address_hash
                     )
                   ]
                 }
               })

      assert AddressTabsElementsCount.get_counter(:token_transfers, from_address.hash) == nil
      assert AddressTabsElementsCount.get_counter(:token_transfers, to_address.hash) == nil
    end

    test "invalidates the ERC-8056 counter only for newly annotated imported transfers" do
      from_address = insert(:address)
      to_address = insert(:address)
      token = insert(:token, extensions: ["ERC-8056"])
      transaction = insert(:transaction) |> with_block()

      AddressTabsElementsCount.set_counter(:token_transfers_erc8056, from_address.hash, 1)
      AddressTabsElementsCount.set_counter(:token_transfers_erc8056, to_address.hash, 1)

      assert {:ok, %{token_transfers: [_token_transfer]}} =
               Chain.import(%{
                 token_transfers: %{
                   params: [
                     params_for(:token_transfer,
                       transaction_hash: transaction.hash,
                       block_hash: transaction.block_hash,
                       block_number: transaction.block_number,
                       from_address_hash: from_address.hash,
                       to_address_hash: to_address.hash,
                       token_contract_address_hash: token.contract_address_hash,
                       ui_amount_status: "ok"
                     )
                   ]
                 }
               })

      refute AddressTabsElementsCount.get_counter(:token_transfers_erc8056, from_address.hash)
      refute AddressTabsElementsCount.get_counter(:token_transfers_erc8056, to_address.hash)
    end

    test "keeps the ERC-8056 counter for unannotated imported transfers" do
      from_address = insert(:address)
      to_address = insert(:address)
      token = insert(:token, extensions: ["ERC-8056"])
      transaction = insert(:transaction) |> with_block()

      AddressTabsElementsCount.set_counter(:token_transfers_erc8056, from_address.hash, 1)
      AddressTabsElementsCount.set_counter(:token_transfers_erc8056, to_address.hash, 1)

      assert {:ok, %{token_transfers: [_token_transfer]}} =
               Chain.import(%{
                 token_transfers: %{
                   params: [
                     params_for(:token_transfer,
                       transaction_hash: transaction.hash,
                       block_hash: transaction.block_hash,
                       block_number: transaction.block_number,
                       from_address_hash: from_address.hash,
                       to_address_hash: to_address.hash,
                       token_contract_address_hash: token.contract_address_hash
                     )
                   ]
                 }
               })

      assert AddressTabsElementsCount.get_counter(:token_transfers_erc8056, from_address.hash)
      assert AddressTabsElementsCount.get_counter(:token_transfers_erc8056, to_address.hash)
    end
  end

  describe "Counters.address_counters/2" do
    test "refreshes transactions count asynchronously" do
      address = insert(:address)

      insert(:transaction, from_address: address) |> with_block()

      assert {_validation_count} = Counters.address_counters(address)
      assert eventually(fn -> AddressTransactionsCount.fetch(address) == 1 end)

      insert(:transaction, to_address: address) |> with_block()
      AddressTransactionsCount.invalidate(address.hash)

      assert {_validation_count} = Counters.address_counters(address)
      assert eventually(fn -> AddressTransactionsCount.fetch(address) == 2 end)
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
