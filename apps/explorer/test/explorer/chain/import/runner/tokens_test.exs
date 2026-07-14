defmodule Explorer.Chain.Import.Runner.TokensTest do
  use Explorer.DataCase

  alias Ecto.Multi
  alias Explorer.Chain.{Address, Token}
  alias Explorer.Chain.Import.Runner.Tokens

  describe "run/1" do
    test "new tokens have their holder_count set to 0" do
      %Address{hash: contract_address_hash} = insert(:address)
      name = "Name"
      type = "ERC-20"

      assert {:ok, %{tokens: [%Token{holder_count: 0}]}} =
               run_changes(%{contract_address_hash: contract_address_hash, type: type, name: name})
    end

    test "existing tokens with nil holder_count do not have their holder_count set to 0" do
      %Token{contract_address_hash: contract_address_hash, type: type, name: name, holder_count: holder_count} =
        insert(:token)

      assert is_nil(holder_count)

      assert {:ok, %{tokens: [%Token{holder_count: ^holder_count}]}} =
               run_changes(%{contract_address_hash: contract_address_hash, type: type, name: name <> "name"})
    end

    test "existing tokens without nil holder counter do have their holder_count change" do
      %Token{contract_address_hash: contract_address_hash, type: type, name: name, holder_count: holder_count} =
        insert(:token, holder_count: 1)

      refute is_nil(holder_count)

      assert {:ok, %{tokens: [%Token{holder_count: ^holder_count}]}} =
               run_changes(%{contract_address_hash: contract_address_hash, type: type, name: name <> "name"})
    end

    test "adds an extension when all metadata is unchanged and preserves existing extensions" do
      token = insert(:token, extensions: ["ERC-7802"])

      changes = %{
        contract_address_hash: token.contract_address_hash,
        type: token.type,
        name: token.name,
        symbol: token.symbol,
        total_supply: token.total_supply,
        decimals: token.decimals,
        extensions: ["ERC-8056"]
      }

      assert {:ok, %{tokens: [_]}} = run_changes(changes)

      reloaded = Repo.get!(Token, token.contract_address_hash)
      assert MapSet.new(reloaded.extensions) == MapSet.new(["ERC-7802", "ERC-8056"])
    end

    test "persists extensions for a new token" do
      %Address{hash: contract_address_hash} = insert(:address)

      assert {:ok, %{tokens: [%Token{extensions: ["ERC-8056"]}]}} =
               run_changes(%{contract_address_hash: contract_address_hash, type: "ERC-20", extensions: ["ERC-8056"]})
    end

    test "does not update when incoming extensions only differ in order" do
      token = insert(:token, extensions: ["ERC-7802", "ERC-8056"])

      assert {:ok, %{filter_token_params: [], tokens: []}} =
               run_changes(%{
                 contract_address_hash: token.contract_address_hash,
                 extensions: ["ERC-8056", "ERC-7802"]
               })
    end

    test "preserves null extensions during an unrelated metadata update" do
      token = insert(:token, extensions: nil)

      assert {:ok, %{tokens: [_]}} =
               run_changes(%{
                 contract_address_hash: token.contract_address_hash,
                 name: "Updated name",
                 type: token.type
               })

      assert Repo.get!(Token, token.contract_address_hash).extensions == nil
    end
  end

  defp run_changes(changes) when is_map(changes) do
    Multi.new()
    |> Tokens.run([changes], %{
      timeout: :infinity,
      timestamps: %{inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
    })
    |> Repo.transaction()
  end
end
