defmodule Explorer.Chain.ScaledUi.TokenStateConcurrencyTest do
  use Explorer.DataCase

  import Ecto.Query, only: [from: 2]
  import Explorer.Factory

  alias Explorer.Chain.{Address, Block, Hash, ScaledUiMultiplierUpdate, Token, Transaction}
  alias Explorer.Chain.ScaledUi.TokenState
  alias Explorer.Repo

  test "concurrent rebuilds lock token rows in one deterministic order" do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    addresses = Enum.map(1..20, fn _ -> insert_unique_address() end)
    hashes = Enum.map(addresses, & &1.hash)

    on_exit(fn -> Repo.delete_all(from(address in Address, where: address.hash in ^hashes)) end)

    ascending_rows = Enum.map(addresses, &%{token_contract_address_hash: &1.hash, capability_block: 100})
    descending_rows = Enum.reverse(ascending_rows)

    results =
      [ascending_rows, descending_rows]
      |> Enum.map(fn rows ->
        Task.async(fn -> Repo.transaction(fn -> TokenState.rebuild(Repo, rows) end, timeout: 10_000) end)
      end)
      |> Enum.map(&Task.await(&1, 15_000))

    assert Enum.all?(results, &match?({:ok, {:ok, _hashes}}, &1))
    assert Repo.aggregate(TokenState, :count) >= 20
  end

  test "a realtime rebuild wins after an older rebuild releases the state lock" do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    parent = self()
    address = insert_unique_address()
    {initial_transaction, initial_addresses} = insert_transaction_with_block()
    {realtime_transaction, realtime_addresses} = insert_transaction_with_block()

    insert_updated(address, initial_transaction, 0, 1_000)
    assert {:ok, [_]} = TokenState.rebuild(Repo, [capability_row(address, initial_transaction.block_number)])

    cleanup_hashes = %{
      addresses: [address.hash | initial_addresses ++ realtime_addresses],
      blocks: [initial_transaction.block_hash, realtime_transaction.block_hash],
      transactions: [initial_transaction.hash, realtime_transaction.hash]
    }

    on_exit(fn -> cleanup(cleanup_hashes) end)

    older_rebuild =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(state in TokenState,
              where: state.token_contract_address_hash == ^address.hash,
              lock: "FOR UPDATE"
            )
          )

          send(parent, :older_rebuild_locked)

          receive do
            :continue_older_rebuild -> :ok
          end

          TokenState.rebuild(Repo, [capability_row(address, initial_transaction.block_number)])
        end)
      end)

    assert_receive :older_rebuild_locked, 5_000

    realtime_rebuild =
      Task.async(fn ->
        Repo.transaction(fn ->
          insert_updated(address, realtime_transaction, 1_000, 2_000)
          send(parent, :realtime_event_inserted)
          TokenState.rebuild(Repo, [capability_row(address, realtime_transaction.block_number)])
        end)
      end)

    assert_receive :realtime_event_inserted, 5_000
    send(older_rebuild.pid, :continue_older_rebuild)

    assert {:ok, {:ok, [_]}} = Task.await(older_rebuild, 10_000)
    assert {:ok, {:ok, [_]}} = Task.await(realtime_rebuild, 10_000)

    state = Repo.get!(TokenState, address.hash)
    assert Decimal.equal?(state.base_multiplier, Decimal.new(2_000))
    assert state.timeline_status == "ok"
  end

  test "rebuild follows token then state lock order" do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    parent = self()
    address = insert_unique_address()
    token = Repo.insert!(%Token{contract_address_hash: address.hash, type: "ERC-20"})
    row = %{token_contract_address_hash: address.hash, capability_block: 100}

    assert {:ok, [_]} = TokenState.rebuild(Repo, [row])

    Repo.update_all(
      from(existing_token in Token, where: existing_token.contract_address_hash == ^address.hash),
      set: [extensions: nil]
    )

    on_exit(fn ->
      Repo.delete_all(from(state in TokenState, where: state.token_contract_address_hash == ^address.hash))
      Repo.delete!(token)
      Repo.delete!(address)
    end)

    token_first =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(locked_token in Token,
              where: locked_token.contract_address_hash == ^address.hash,
              lock: "FOR NO KEY UPDATE"
            )
          )

          send(parent, :token_locked)

          receive do
            :lock_state -> :ok
          end

          Repo.one!(
            from(state in TokenState, where: state.token_contract_address_hash == ^address.hash, lock: "FOR UPDATE")
          )
        end)
      end)

    assert_receive :token_locked, 5_000

    rebuild =
      Task.async(fn ->
        Repo.transaction(fn -> TokenState.rebuild(Repo, [row]) end, timeout: 10_000)
      end)

    refute Task.yield(rebuild, 100)
    send(token_first.pid, :lock_state)

    assert {:ok, %TokenState{}} = Task.await(token_first, 10_000)
    assert {:ok, {:ok, [_]}} = Task.await(rebuild, 10_000)
  end

  defp capability_row(address, block_number) do
    %{token_contract_address_hash: address.hash, capability_block: block_number}
  end

  defp insert_updated(address, transaction, old_multiplier, new_multiplier) do
    timestamp = DateTime.to_unix(transaction.block.timestamp)

    %ScaledUiMultiplierUpdate{}
    |> ScaledUiMultiplierUpdate.changeset(%{
      token_contract_address_hash: address.hash,
      transaction_hash: transaction.hash,
      block_hash: transaction.block_hash,
      block_number: transaction.block_number,
      block_timestamp: Decimal.new(timestamp),
      log_index: 1,
      event_type: "updated",
      old_multiplier: Decimal.new(old_multiplier),
      new_multiplier: Decimal.new(new_multiplier),
      effective_at: Decimal.new(timestamp)
    })
    |> Repo.insert!()
  end

  defp insert_transaction_with_block do
    from_address = insert_unique_address()
    miner = insert_unique_address()
    to_address = insert_unique_address()

    block =
      insert(:block,
        hash: random_hash(32),
        miner: miner,
        number: :erlang.unique_integer([:positive]),
        parent_hash: random_hash(32)
      )

    transaction =
      insert(:transaction,
        from_address: from_address,
        hash: random_hash(32),
        to_address: to_address
      )
      |> with_block(block)

    {transaction, [from_address.hash, miner.hash, to_address.hash]}
  end

  defp insert_unique_address, do: Repo.insert!(%Address{hash: random_hash(20)})
  defp random_hash(byte_count), do: %Hash{byte_count: byte_count, bytes: :crypto.strong_rand_bytes(byte_count)}

  defp cleanup(%{addresses: address_hashes, blocks: block_hashes, transactions: transaction_hashes}) do
    token_address_hash = hd(address_hashes)

    Repo.delete_all(
      from(event in ScaledUiMultiplierUpdate, where: event.token_contract_address_hash == ^token_address_hash)
    )

    Repo.delete_all(from(state in TokenState, where: state.token_contract_address_hash == ^token_address_hash))
    Repo.delete_all(from(transaction in Transaction, where: transaction.hash in ^transaction_hashes))
    Repo.delete_all(from(block in Block, where: block.hash in ^block_hashes))
    Repo.delete_all(from(address in Address, where: address.hash in ^address_hashes))
  end
end
