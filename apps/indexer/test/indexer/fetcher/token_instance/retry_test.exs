# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.Fetcher.TokenInstance.RetryTest do
  use Explorer.DataCase

  alias Explorer.Repo
  alias Indexer.Fetcher.TokenInstance.Retry

  describe "init/3" do
    setup do
      previous_config = Application.get_env(:indexer, Retry)
      Application.put_env(:indexer, Retry, Keyword.put(previous_config, :init_limit, 2))
      on_exit(fn -> Application.put_env(:indexer, Retry, previous_config) end)

      token = insert(:token, type: "ERC-721")
      due = DateTime.add(DateTime.utc_now(), -60)

      for token_id <- 1..3 do
        insert(:token_instance,
          token_id: token_id,
          token_contract_address_hash: token.contract_address_hash,
          metadata: nil,
          error: "request error: 404",
          refetch_after: due
        )
      end

      %{token: token}
    end

    # Unbounded, the init read every failed instance in one go, so a large backlog
    # meant a long init. Each init must read a bounded batch; the BufferedTask polls
    # for the next batch once the queue drains.
    test "reads at most the configured init limit of instances to retry" do
      result = Retry.init([], fn data, acc -> [data | acc] end, [])

      assert length(result) == 2
    end

    # The reducer can block while the fetcher's queue is full. Run inside the
    # query's transaction, that wait kept the transaction idle for hours, which held
    # back vacuum for the whole database.
    test "hands instances to the reducer outside a database transaction" do
      reducer = fn data, acc -> [{data, Repo.in_transaction?()} | acc] end

      result = Retry.init([], reducer, [])

      assert result != []
      assert Enum.all?(result, fn {_data, in_transaction?} -> not in_transaction? end)
    end

    # A collection refetch requested on demand marks its instances without a
    # `refetch_after`. Each batch starts from the head of the order, so if those rows
    # sorted after the dated retries, a backlog of dated retries would hold them back
    # for as long as it lasted.
    test "takes instances marked for refetch before dated retries", %{token: token} do
      insert(:token_instance,
        token_id: 4,
        token_contract_address_hash: token.contract_address_hash,
        metadata: nil,
        error: ":marked_to_refetch",
        refetch_after: nil
      )

      result = Retry.init([], fn data, acc -> [data | acc] end, [])

      assert Enum.any?(result, &Decimal.equal?(&1.token_id, 4))
    end
  end
end
