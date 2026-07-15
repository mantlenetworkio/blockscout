defmodule Explorer.Chain.Import.Runner.ScaledUiTokenStatesTest do
  use Explorer.DataCase

  alias Ecto.Multi
  alias Explorer.Chain.{ScaledUiMultiplierUpdate, Token}
  alias Explorer.Chain.Import.Runner.{ScaledUiMultiplierUpdates, ScaledUiTokenStates}
  alias Explorer.Chain.Import.Stage.TokenReferencing
  alias Explorer.Chain.ScaledUi.TokenState
  alias Explorer.Repo

  describe "run/3" do
    test "runs timeline inserts immediately before state rebuilds" do
      runners = TokenReferencing.runners()

      assert Enum.find_index(runners, &(&1 == ScaledUiTokenStates)) ==
               Enum.find_index(runners, &(&1 == ScaledUiMultiplierUpdates)) + 1
    end

    test "rebuilds capability state without multiplier update params" do
      address = insert(:address)

      assert {:ok, %{scaled_ui_token_states: [address.hash]}} ==
               run_states([%{token_contract_address_hash: address.hash, capability_block: 25}])

      assert Repo.get!(TokenState, address.hash).capability_block == 25
      assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 0
      refute Repo.get(Token, address.hash)
    end

    test "adds ERC-8056 to an existing token for a capability-only batch" do
      token = insert(:token, extensions: ["ERC-7802"])

      assert {:ok, %{scaled_ui_token_states: [token.contract_address_hash]}} ==
               run_states([
                 %{token_contract_address_hash: token.contract_address_hash, capability_block: 25}
               ])

      assert MapSet.new(Repo.get!(Token, token.contract_address_hash).extensions) ==
               MapSet.new(["ERC-7802", "ERC-8056"])
    end

    test "rolls timeline inserts back when state rebuild fails" do
      token_address = insert(:contract_address)
      transaction = insert(:transaction) |> with_block()
      block = transaction.block

      timeline_changes = [
        %{
          token_contract_address_hash: token_address.hash,
          transaction_hash: transaction.hash,
          block_hash: block.hash,
          block_number: block.number,
          block_timestamp: Decimal.new(DateTime.to_unix(block.timestamp)),
          log_index: 1,
          event_type: "updated",
          old_multiplier: Decimal.new(0),
          new_multiplier: Decimal.new(1_000),
          effective_at: Decimal.new(DateTime.to_unix(block.timestamp))
        }
      ]

      missing_address_hash = address_hash()
      options = %{timestamps: Explorer.Chain.Import.timestamps()}

      assert_raise Postgrex.Error, fn ->
        Multi.new()
        |> ScaledUiMultiplierUpdates.run(timeline_changes, options)
        |> ScaledUiTokenStates.run(
          [%{token_contract_address_hash: missing_address_hash, capability_block: block.number}],
          options
        )
        |> Repo.transaction()
      end

      assert Repo.aggregate(ScaledUiMultiplierUpdate, :count) == 0
    end
  end

  defp run_states(changes_list) do
    Multi.new()
    |> ScaledUiTokenStates.run(changes_list, %{timestamps: Explorer.Chain.Import.timestamps()})
    |> Repo.transaction()
  end
end
