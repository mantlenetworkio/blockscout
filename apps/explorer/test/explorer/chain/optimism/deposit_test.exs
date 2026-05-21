defmodule Explorer.Chain.Optimism.DepositTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Chain.Optimism.Deposit

    describe "list/1" do
      test "returns all deposits when :address_hash is not provided" do
        insert_list(3, :op_deposit)

        result = Deposit.list()

        assert length(result) == 3
      end

      test "returns only deposits whose l1_transaction_origin matches :address_hash" do
        target_address = build(:address)
        target_hash = target_address.hash

        matching = insert(:op_deposit, l1_transaction_origin: target_hash)
        insert(:op_deposit)
        insert(:op_deposit)

        result = Deposit.list(address_hash: target_hash)

        assert [returned] = result
        assert returned.l2_transaction_hash == matching.l2_transaction_hash
        assert returned.l1_transaction_origin == target_hash
      end

      test "returns empty list when no deposits match :address_hash" do
        insert_list(2, :op_deposit)
        other_address = build(:address)

        assert [] == Deposit.list(address_hash: other_address.hash)
      end

      test "treats :address_hash nil the same as omitted" do
        insert_list(2, :op_deposit)

        result_with_nil = Deposit.list(address_hash: nil)
        result_without_opt = Deposit.list()

        assert length(result_with_nil) == length(result_without_opt)
      end
    end

    describe "count/1" do
      test "returns total count when :address_hash is not provided" do
        insert_list(4, :op_deposit)

        assert Deposit.count() == 4
      end

      test "returns count filtered by :address_hash" do
        target_address = build(:address)
        target_hash = target_address.hash

        insert(:op_deposit, l1_transaction_origin: target_hash)
        insert(:op_deposit, l1_transaction_origin: target_hash)
        insert(:op_deposit)
        insert(:op_deposit)

        assert Deposit.count(address_hash: target_hash) == 2
      end

      test "returns 0 when no deposits match :address_hash" do
        insert_list(3, :op_deposit)
        other_address = build(:address)

        assert Deposit.count(address_hash: other_address.hash) == 0
      end
    end
  end
end
