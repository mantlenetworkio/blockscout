defmodule Explorer.Chain.PendingOperationsHelperTest do
  use Explorer.DataCase

  alias Explorer.Chain.{Hash, PendingOperationsHelper, PendingTransactionOperation, Transaction}

  describe "insert_pending_operations/2 in \"transactions\" mode" do
    setup do
      json_rpc_config = Application.get_env(:explorer, :json_rpc_named_arguments)

      Application.put_env(
        :explorer,
        :json_rpc_named_arguments,
        Keyword.put(json_rpc_config || [], :variant, EthereumJSONRPC.Geth)
      )

      geth_config = Application.get_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth)

      Application.put_env(
        :ethereum_jsonrpc,
        EthereumJSONRPC.Geth,
        Keyword.put(geth_config || [], :block_traceable?, false)
      )

      on_exit(fn ->
        Application.put_env(:explorer, :json_rpc_named_arguments, json_rpc_config)
        Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Geth, geth_config)
      end)

      :ok
    end

    # regression: blocks with tens of thousands of transactions used to crash the
    # insert with "postgresql protocol can not handle N parameters, the maximum
    # is 65535" (4 params per row x >16384 rows in a single insert_all)
    test "handles blocks whose transaction count exceeds the postgres parameter limit" do
      block = insert(:block)

      template_transaction =
        :transaction
        |> insert()
        |> with_block(block, status: :ok)

      base =
        Transaction
        |> Repo.get!(template_transaction.hash)
        |> Map.take([
          :hash,
          :block_hash,
          :block_number,
          :block_timestamp,
          :index,
          :cumulative_gas_used,
          :gas_used,
          :status,
          :gas,
          :gas_price,
          :input,
          :nonce,
          :r,
          :s,
          :v,
          :value,
          :from_address_hash,
          :to_address_hash,
          :fhe_operations_count,
          :inserted_at,
          :updated_at
        ])

      # 16401 transactions x 4 params per pending operation row = 65604 > 65535
      extra_transactions_count = 16_400

      rows =
        for index <- 1..extra_transactions_count do
          %{base | hash: numeric_transaction_hash(index), index: index, nonce: index}
        end

      Repo.safe_insert_all(Transaction, rows, [])

      assert {[], transactions} = PendingOperationsHelper.insert_pending_operations([block.number])

      assert length(transactions) == extra_transactions_count + 1
      assert Repo.aggregate(PendingTransactionOperation, :count, :transaction_hash) == extra_transactions_count + 1
    end

    test "returns transactions with the fields required by the internal transactions fetcher" do
      transaction =
        :transaction
        |> insert()
        |> with_block(status: :ok)

      assert {[], [returned]} = PendingOperationsHelper.insert_pending_operations([transaction.block_number])

      assert %{block_number: block_number, hash: hash, index: index, type: _type} = returned
      assert block_number == transaction.block_number
      assert hash == transaction.hash
      assert index == transaction.index

      assert [%{transaction_hash: ^hash}] = Repo.all(PendingTransactionOperation)
    end
  end

  defp numeric_transaction_hash(index) do
    %Hash{byte_count: 32, bytes: <<1_000_000 + index::big-integer-size(256)>>}
  end
end
