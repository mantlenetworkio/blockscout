defmodule Explorer.Chain.Cache.Counters.AddressTabsElementsCountTest do
  use Explorer.DataCase

  import Explorer.Factory

  alias Explorer.Chain.Cache.Counters.AddressTabsElementsCount

  describe "get_counter/2" do
    test "treats limit counters as stale after ttl expires" do
      old_env = Application.get_env(:explorer, AddressTabsElementsCount)
      Application.put_env(:explorer, AddressTabsElementsCount, ttl: 100)

      on_exit(fn ->
        Application.put_env(:explorer, AddressTabsElementsCount, old_env)
      end)

      address = build(:address)

      AddressTabsElementsCount.set_counter(:logs, address.hash, 51)

      assert {_datetime, 51, :limit_value} = AddressTabsElementsCount.get_counter(:logs, address.hash)

      :timer.sleep(120)

      assert {_datetime, 51, :stale} = AddressTabsElementsCount.get_counter(:logs, address.hash)
    end
  end

  describe "invalidate_transactions_counter/1" do
    test "drops transactions counter and in-flight task markers" do
      address = build(:address)

      AddressTabsElementsCount.set_counter(:transactions, address.hash, 1)
      AddressTabsElementsCount.set_task(:transactions_from, address.hash)

      AddressTabsElementsCount.invalidate_transactions_counter(address.hash)

      assert AddressTabsElementsCount.get_counter(:transactions, address.hash) == nil
      assert AddressTabsElementsCount.get_task(:transactions_from, address.hash) == nil
    end
  end

  describe "invalidate_counter/2" do
    test "drops counter and in-flight task marker" do
      address = build(:address)

      AddressTabsElementsCount.set_counter(:token_transfers, address.hash, 1)
      AddressTabsElementsCount.set_task(:token_transfers, address.hash)

      AddressTabsElementsCount.invalidate_counter(:token_transfers, address.hash)

      assert AddressTabsElementsCount.get_counter(:token_transfers, address.hash) == nil
      assert AddressTabsElementsCount.get_task(:token_transfers, address.hash) == nil
    end
  end
end
