defmodule Explorer.Chain.Import.Runner.BlocksScaledUiTest do
  use Explorer.DataCase

  alias Ecto.Multi
  alias Explorer.Chain.{Block, Hash, ScaledUiMultiplierUpdate, Token}
  alias Explorer.Chain.Cache.Counters.AddressTabsElementsCount
  alias Explorer.Chain.Import.Runner.Blocks
  alias Explorer.Chain.ScaledUi.{Events, TokenState}
  alias Explorer.{Chain, Repo}

  describe "scaled UI reorg rollback" do
    test "replays the remaining timeline and clears an orphan taint" do
      token = insert(:token, extensions: ["ERC-8056"])
      parent = insert(:block, consensus: true)

      first_block =
        insert(:block, number: parent.number + 1, parent_hash: parent.hash, consensus: true)

      orphan =
        insert(:block,
          number: first_block.number + 1,
          parent_hash: first_block.hash,
          consensus: true
        )

      insert_update(token, first_block, 0, 1_000, 1)
      insert_update(token, orphan, 999, 2_000, 1)
      insert_capability_log(token, first_block, 2)
      insert_capability_log(token, orphan, 2)

      assert {:ok, [_]} = TokenState.rebuild(Repo, [capability_row(token, first_block.number)])
      assert Repo.get!(TokenState, token.contract_address_hash).timeline_status == "tainted"

      assert {:ok, %{scaled_ui_reorg: result}} = replace_block(orphan, first_block.hash)

      state = Repo.get!(TokenState, token.contract_address_hash)
      assert Decimal.equal?(state.base_multiplier, Decimal.new(1_000))
      assert state.timeline_status == "ok"
      assert state.tainted_from_block == nil
      assert result.removed_token_hashes == []
      assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 1
    end

    test "moves capability to the earliest remaining canonical event" do
      token = insert(:token, extensions: ["ERC-8056"])
      parent = insert(:block, consensus: true)

      orphan =
        insert(:block, number: parent.number + 1, parent_hash: parent.hash, consensus: true)

      replacement =
        insert(:block, number: orphan.number, parent_hash: parent.hash, consensus: false)

      later =
        insert(:block, number: orphan.number + 1, parent_hash: replacement.hash, consensus: true)

      insert_capability_log(token, orphan, 1)
      insert_capability_log(token, later, 1)
      assert {:ok, [_]} = TokenState.rebuild(Repo, [capability_row(token, orphan.number)])

      assert {:ok, %{scaled_ui_reorg: %{removed_token_hashes: []}}} =
               replace_block(orphan, parent.hash,
                 hash: replacement.hash,
                 miner_hash: replacement.miner_hash
               )

      assert Repo.get!(TokenState, token.contract_address_hash).capability_block == later.number
    end

    test "removes capability and summaries while retaining interface results" do
      token = insert(:token, extensions: ["ERC-7802", "ERC-8056"])
      only_scaled_ui_token = insert(:token, extensions: ["ERC-8056"])
      parent = insert(:block, consensus: true)

      orphan =
        insert(:block, number: parent.number + 1, parent_hash: parent.hash, consensus: true)

      insert_update(token, orphan, 0, 1_000, 1)
      insert_capability_log(token, orphan, 2)
      insert_capability_log(only_scaled_ui_token, orphan, 3)

      assert {:ok, [_, _]} =
               TokenState.rebuild(Repo, [
                 capability_row(token, orphan.number),
                 capability_row(only_scaled_ui_token, orphan.number)
               ])

      state = Repo.get!(TokenState, token.contract_address_hash)

      state
      |> TokenState.changeset(%{iface_checked: true, core_ext: true, scheduled_ext: false})
      |> Repo.update!()

      assert {:ok, %{scaled_ui_reorg: result}} = replace_block(orphan, parent.hash)

      assert MapSet.new(result.removed_token_hashes) ==
               MapSet.new([
                 token.contract_address_hash,
                 only_scaled_ui_token.contract_address_hash
               ])

      assert Repo.get!(Token, token.contract_address_hash).extensions == ["ERC-7802"]
      assert Repo.get!(Token, only_scaled_ui_token.contract_address_hash).extensions == nil

      state = Repo.get!(TokenState, token.contract_address_hash)
      assert state.capability_block == nil
      assert state.base_multiplier == nil
      assert state.pending_multiplier == nil
      assert state.timeline_status == nil
      assert state.iface_checked == true
      assert state.core_ext == true
      assert state.scheduled_ext == false
    end

    test "invalidates counters only after a successful import" do
      token = insert(:token, extensions: ["ERC-8056"])
      parent = insert(:block, consensus: true)

      orphan =
        insert(:block, number: parent.number + 1, parent_hash: parent.hash, consensus: true)

      from_address = insert(:address)
      to_address = insert(:address)
      transaction = insert(:transaction) |> with_block(orphan)

      insert_update(token, orphan, 0, 1_000, 1)
      insert_capability_log(token, orphan, 2)
      assert {:ok, [_]} = TokenState.rebuild(Repo, [capability_row(token, orphan.number)])

      insert(:token_transfer,
        block: orphan,
        block_number: orphan.number,
        from_address: from_address,
        to_address: to_address,
        token_contract_address: token.contract_address,
        token_type: token.type,
        transaction: transaction,
        ui_amount_status: "ok"
      )

      AddressTabsElementsCount.set_counter(:token_transfers, from_address.hash, 1)
      AddressTabsElementsCount.set_counter(:token_transfers_erc8056, from_address.hash, 1)

      params = replacement_params(orphan, parent.hash)
      changes = Block.changeset(%Block{}, params).changes
      now = DateTime.utc_now()

      assert {:error, :forced_failure, :boom, _changes} =
               Multi.new()
               |> Blocks.run([changes], %{timestamps: %{inserted_at: now, updated_at: now}})
               |> Multi.run(:forced_failure, fn _repo, _changes -> {:error, :boom} end)
               |> Repo.transaction()

      assert AddressTabsElementsCount.get_counter(:token_transfers, from_address.hash)
      assert AddressTabsElementsCount.get_counter(:token_transfers_erc8056, from_address.hash)
      assert Repo.get!(Block, orphan.hash).consensus
      assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 1

      assert {:ok, %{scaled_ui_reorg: _result}} = Chain.import(%{blocks: %{params: [params]}})
      refute AddressTabsElementsCount.get_counter(:token_transfers, from_address.hash)
      refute AddressTabsElementsCount.get_counter(:token_transfers_erc8056, from_address.hash)
    end
  end

  defp replace_block(orphan, parent_hash, overrides \\ []) do
    replacement_params = replacement_params(orphan, parent_hash, overrides)

    changes = Block.changeset(%Block{}, replacement_params).changes
    now = DateTime.utc_now()

    Multi.new()
    |> Blocks.run([changes], %{timestamps: %{inserted_at: now, updated_at: now}})
    |> Repo.transaction()
  end

  defp replacement_params(orphan, parent_hash, overrides \\ []) do
    miner = insert(:address)

    :block
    |> params_for(
      miner_hash: miner.hash,
      number: orphan.number,
      parent_hash: parent_hash,
      consensus: true
    )
    |> Map.merge(Map.new(overrides))
  end

  defp insert_update(token, block, old_multiplier, new_multiplier, log_index) do
    transaction = insert(:transaction) |> with_block(block)
    timestamp = Decimal.new(DateTime.to_unix(block.timestamp))

    %ScaledUiMultiplierUpdate{}
    |> ScaledUiMultiplierUpdate.changeset(%{
      token_contract_address_hash: token.contract_address_hash,
      transaction_hash: transaction.hash,
      block_hash: block.hash,
      block_number: block.number,
      block_timestamp: timestamp,
      log_index: log_index,
      event_type: "updated",
      old_multiplier: Decimal.new(old_multiplier),
      new_multiplier: Decimal.new(new_multiplier),
      effective_at: timestamp
    })
    |> Repo.insert!()
  end

  defp insert_capability_log(token, block, log_index) do
    transaction = insert(:transaction) |> with_block(block)
    {:ok, topic} = Hash.Full.cast(Events.ui_multiplier_updated_topic())

    insert(:log,
      address: token.contract_address,
      block: block,
      block_number: block.number,
      first_topic: topic,
      index: log_index,
      transaction: transaction
    )
  end

  defp capability_row(token, block_number) do
    %{token_contract_address_hash: token.contract_address_hash, capability_block: block_number}
  end
end
