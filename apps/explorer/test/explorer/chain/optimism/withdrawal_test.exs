defmodule Explorer.Chain.Optimism.WithdrawalTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Chain.Optimism.Withdrawal
    alias Explorer.Repo

    defp insert_withdrawal(opts \\ []) do
      transaction = insert(:transaction, Keyword.take(opts, [:from_address]))

      Repo.insert!(%Withdrawal{
        msg_nonce: Decimal.new(System.unique_integer([:positive])),
        hash: Explorer.Factory.transaction_hash(),
        l2_transaction_hash: transaction.hash,
        l2_block_number: transaction.block_number || 1
      })
    end

    describe "list/1" do
      test "returns all withdrawals when :address_hash is not provided" do
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()

        result = Withdrawal.list()

        assert length(result) == 3
      end

      test "returns only withdrawals whose l2_transaction.from_address_hash matches :address_hash" do
        target_address = insert(:address)
        target_hash = target_address.hash

        matching = insert_withdrawal(from_address: target_address)
        insert_withdrawal()
        insert_withdrawal()

        result = Withdrawal.list(address_hash: target_hash)

        assert [returned] = result
        assert returned.msg_nonce == matching.msg_nonce
        assert returned.from == target_hash
      end

      test "returns empty list when no withdrawals match :address_hash" do
        insert_withdrawal()
        insert_withdrawal()
        other_address = insert(:address)

        assert [] == Withdrawal.list(address_hash: other_address.hash)
      end

      test "treats :address_hash nil the same as omitted" do
        insert_withdrawal()
        insert_withdrawal()

        result_with_nil = Withdrawal.list(address_hash: nil)
        result_without_opt = Withdrawal.list()

        assert length(result_with_nil) == length(result_without_opt)
      end
    end

    describe "count/1" do
      test "returns total count when :address_hash is not provided" do
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()

        assert Withdrawal.count() == 4
      end

      test "returns count filtered by :address_hash" do
        target_address = insert(:address)
        target_hash = target_address.hash

        insert_withdrawal(from_address: target_address)
        insert_withdrawal(from_address: target_address)
        insert_withdrawal()
        insert_withdrawal()

        assert Withdrawal.count(address_hash: target_hash) == 2
      end

      test "returns 0 when no withdrawals match :address_hash" do
        insert_withdrawal()
        insert_withdrawal()
        insert_withdrawal()
        other_address = insert(:address)

        assert Withdrawal.count(address_hash: other_address.hash) == 0
      end
    end
  end
end
