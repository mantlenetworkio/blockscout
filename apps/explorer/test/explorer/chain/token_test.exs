# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.TokenTest do
  use Explorer.DataCase

  import Explorer.Factory

  alias Explorer.Chain.{Address, Token}
  alias Explorer.Repo

  describe "cataloged_tokens/0" do
    test "filters only cataloged tokens" do
      {:ok, date} = DateTime.now("Etc/UTC")
      hours_ago_date = DateTime.add(date, -:timer.hours(60), :millisecond)
      token = insert(:token, cataloged: true, metadata_updated_at: hours_ago_date)
      insert(:token, cataloged: false)

      [token_from_db] = Repo.all(Token.cataloged_tokens())

      assert token_from_db.contract_address_hash == token.contract_address_hash
    end

    test "filters cataloged tokens with nil metadata_updated_at" do
      token = insert(:token, cataloged: true, metadata_updated_at: nil)

      [token_from_db] = Repo.all(Token.cataloged_tokens())

      assert token_from_db.contract_address_hash == token.contract_address_hash
    end

    test "filter tokens by metadata_updated_at field" do
      {:ok, date} = DateTime.now("Etc/UTC")
      hours_ago_date = DateTime.add(date, -:timer.hours(60), :millisecond)

      token = insert(:token, cataloged: true, metadata_updated_at: hours_ago_date)

      [token_from_db] = Repo.all(Token.cataloged_tokens())

      assert token_from_db.contract_address_hash == token.contract_address_hash
    end
  end

  describe "stream_cataloged_tokens/2" do
    test "reduces with given reducer and accumulator" do
      today = DateTime.utc_now()
      yesterday = Timex.shift(today, days: -1)
      token = insert(:token, cataloged: true, metadata_updated_at: yesterday)
      insert(:token, cataloged: false)
      {:ok, [token_from_func]} = Token.stream_cataloged_tokens([], &[&1 | &2], 1)
      assert token_from_func.contract_address_hash == token.contract_address_hash
    end

    test "sorts the tokens by metadata_updated_at in ascending order" do
      today = DateTime.utc_now()
      yesterday = Timex.shift(today, days: -1)
      two_days_ago = Timex.shift(today, days: -2)

      token1 = insert(:token, %{cataloged: true, metadata_updated_at: yesterday})
      token2 = insert(:token, %{cataloged: true, metadata_updated_at: two_days_ago})

      expected_response =
        [token1, token2]
        |> Enum.sort(&(Timex.to_unix(&1.metadata_updated_at) < Timex.to_unix(&2.metadata_updated_at)))
        |> Enum.map(& &1.contract_address_hash)

      {:ok, response} = Token.stream_cataloged_tokens([], &(&2 ++ [&1]), 12)

      formatted_response =
        response
        |> Enum.sort(&(Timex.to_unix(&1.metadata_updated_at) < Timex.to_unix(&2.metadata_updated_at)))
        |> Enum.map(& &1.contract_address_hash)

      assert formatted_response == expected_response
    end
  end

  describe "update/2" do
    test "updates a token's values" do
      token = insert(:token, name: nil, symbol: nil, total_supply: nil, decimals: nil, cataloged: false)

      update_params = %{
        name: "Hodl Token",
        symbol: "HT",
        total_supply: 10,
        decimals: Decimal.new(1),
        cataloged: true
      }

      assert {:ok, updated_token} = Token.update(token, update_params)
      assert updated_token.name == update_params.name
      assert updated_token.symbol == update_params.symbol
      assert updated_token.total_supply == Decimal.new(update_params.total_supply)
      assert updated_token.decimals == update_params.decimals
      assert updated_token.cataloged
    end

    test "trims names of whitespace" do
      token = insert(:token, name: nil, symbol: nil, total_supply: nil, decimals: nil, cataloged: false)

      update_params = %{
        name: "      Hodl Token     ",
        symbol: "HT",
        total_supply: 10,
        decimals: 1,
        cataloged: true
      }

      assert {:ok, updated_token} = Token.update(token, update_params)
      assert updated_token.name == "Hodl Token"
      assert Repo.get_by(Address.Name, name: "Hodl Token")
    end

    test "inserts an address name record when token has a name in params" do
      token = insert(:token, name: nil, symbol: nil, total_supply: nil, decimals: nil, cataloged: false)

      update_params = %{
        name: "Hodl Token",
        symbol: "HT",
        total_supply: 10,
        decimals: 1,
        cataloged: true
      }

      Token.update(token, update_params)
      assert Repo.get_by(Address.Name, name: update_params.name, address_hash: token.contract_address_hash)
    end

    test "does not insert address name record when token doesn't have name in params" do
      token = insert(:token, name: nil, symbol: nil, total_supply: nil, decimals: nil, cataloged: false)

      update_params = %{
        cataloged: true
      }

      Token.update(token, update_params)
      refute Repo.get_by(Address.Name, address_hash: token.contract_address_hash)
    end

    test "stores token with big 'decimals' values" do
      token = insert(:token, name: nil, symbol: nil, total_supply: nil, decimals: nil, cataloged: false)

      update_params = %{
        name: "Hodl Token",
        symbol: "HT",
        total_supply: 10,
        decimals: 1_000_000_000_000_000_000,
        cataloged: true
      }

      assert {:ok, _updated_token} = Token.update(token, update_params)
    end
  end

  describe "list_top/2" do
    test "returns market data with enabled token fetcher" do
      old_source_env = Application.get_env(:explorer, Explorer.Market.Source)
      old_fetcher_env = Application.get_env(:explorer, Explorer.Market.Fetcher.Token)

      Application.put_env(
        :explorer,
        Explorer.Market.Source,
        Keyword.merge(old_source_env, tokens_source: Explorer.Market.Source.OneCoinSource)
      )

      Application.put_env(:explorer, Explorer.Market.Fetcher.Token, Keyword.merge(old_fetcher_env, enabled: true))

      on_exit(fn ->
        Application.put_env(:explorer, Explorer.Market.Source, old_source_env)
        Application.put_env(:explorer, Explorer.Market.Fetcher.Token, old_fetcher_env)
      end)

      start_supervised!(Explorer.Market.Fetcher.Token)
      start_supervised!(Explorer.Market)

      insert_list(10, :token)

      market_data = Token.list_top(nil)

      assert Enum.all?(market_data, fn token -> not is_nil(token.fiat_value) end)
    end

    test "ignores market data with disabled token fetcher" do
      insert_list(10, :token)

      start_supervised!(Explorer.Market)

      market_data = Token.list_top(nil)

      assert Enum.all?(market_data, fn token -> is_nil(token.fiat_value) end)
    end

    test "finds token by contract address hash" do
      token = insert(:token, name: "Token that we search for", symbol: "ATK")
      insert(:token)
      insert(:token)
      insert(:token)

      address_hash_string = to_string(token.contract_address_hash)

      results = Token.list_top(address_hash_string)

      assert [%{name: "Token that we search for"}] = results
    end

    test "finds token by contract address hash when given mixed-case address" do
      contract_address = insert(:contract_address, hash: "0xdAC17F958D2ee523a2206206994597C13D831ec7")
      insert(:token, contract_address: contract_address, name: "Token that we search for", symbol: "ATK")
      insert(:token)
      insert(:token)
      insert(:token)

      results = Token.list_top("0xDAC17F958D2EE523A2206206994597C13D831EC7")

      assert [%{name: "Token that we search for"}] = results
    end

    test "returns empty when searching with a valid address hash format that has no token" do
      insert(:token, name: "Some Token", symbol: "STK")
      non_existent_hash = "0xf000000000000000000000000000000000000000"

      results = Token.list_top(non_existent_hash)

      assert Enum.empty?(results)
    end

    test "falls back to full-text search for invalid address hash format" do
      insert(:token, name: "0xINVALID_HEX Token", symbol: "IHT")
      insert(:token)
      insert(:token)
      insert(:token)

      results = Token.list_top("0xINVALID_HEX")

      assert [%{name: "0xINVALID_HEX Token"}] = results
    end
  end

  describe "onchain_market_cap" do
    setup do
      initial_value = :persistent_term.get(:market_token_fetcher_enabled, false)
      :persistent_term.put(:market_token_fetcher_enabled, true)
      on_exit(fn -> :persistent_term.put(:market_token_fetcher_enabled, initial_value) end)
    end

    test "is the price times the total supply in whole tokens" do
      token = insert(:token, fiat_value: Decimal.new("2.5"), total_supply: 4_000_000, decimals: 6)

      assert Decimal.equal?(token.onchain_market_cap, 10)
      assert Decimal.equal?(reload(token).onchain_market_cap, 10)
    end

    test "follows supply and price updates" do
      token = insert(:token, fiat_value: 1, total_supply: 1_000_000, decimals: 6)

      assert {:ok, updated} = Token.update(token, %{total_supply: 3_000_000})
      assert Decimal.equal?(updated.onchain_market_cap, 3)

      assert {:ok, %{tokens: [_]}} =
               Explorer.Chain.import(%{
                 tokens: %{
                   params: [
                     %{
                       contract_address_hash: token.contract_address_hash,
                       type: token.type,
                       fiat_value: Decimal.new(2),
                       circulating_market_cap: Decimal.new(1_000_000)
                     }
                   ],
                   on_conflict: Explorer.Chain.Import.Runner.Tokens.market_data_on_conflict(),
                   fields_to_update: Explorer.Chain.Import.Runner.Tokens.market_data_fields_to_update()
                 }
               })

      assert Decimal.equal?(reload(token).onchain_market_cap, 6)
    end

    test "is nil without a price, a total supply or decimals" do
      assert is_nil(insert(:token, fiat_value: nil).onchain_market_cap)
      assert is_nil(insert(:token, total_supply: nil).onchain_market_cap)
      assert is_nil(insert(:token, decimals: nil).onchain_market_cap)
    end

    test "is nil for decimals above 78 instead of failing the write" do
      token = insert(:token, fiat_value: 1, total_supply: 10, decimals: 18)

      assert {:ok, updated} = Token.update(token, %{decimals: 1_000_000_000_000_000_000})
      assert is_nil(updated.onchain_market_cap)
    end

    test "orders the token list by default, ahead of the all-chain market cap" do
      # tiny supply here, big market cap on other chains
      small = insert(:token, fiat_value: 9, total_supply: 10_000_000_000_000, circulating_market_cap: 7_000_000_000)
      big = insert(:token, fiat_value: 1, total_supply: 400 * 1_000_000_000_000_000_000, circulating_market_cap: 1)
      no_supply = insert(:token, fiat_value: 1, total_supply: 0, circulating_market_cap: 1_000_000_000)
      no_price = insert(:token, fiat_value: nil)

      assert Token.list_top(nil) |> Enum.map(& &1.contract_address_hash) ==
               Enum.map([big, small, no_supply, no_price], & &1.contract_address_hash)
    end

    defp reload(token), do: Repo.get_by!(Token, contract_address_hash: token.contract_address_hash)
  end

  describe "list_top/2 symbol substring match" do
    test "a single word of at least 3 characters matches inside symbols" do
      wmnt = insert(:token, name: "Wrapped Mantle", symbol: "WMNT")
      mnt = insert(:token, name: "Mantle Token", symbol: "MNT")
      insert(:token, name: "Ether", symbol: "WETH")
      # the full-text match skips symbol-only tokens too
      insert(:token, name: nil, symbol: "XMNT")

      assert "mnt" |> Token.list_top() |> hashes() == hashes([wmnt, mnt])
      assert "MNT" |> Token.list_top() |> hashes() == hashes([wmnt, mnt])
    end

    test "shorter words and multi-word terms keep the prefix-only match" do
      insert(:token, name: "Wrapped Mantle", symbol: "WMNT")
      mnt = insert(:token, name: "Mantle Token", symbol: "MNT")

      assert "mn" |> Token.list_top() |> hashes() == hashes([mnt])
      assert "mantle mnt" |> Token.list_top() |> hashes() == hashes([mnt])
    end

    defp hashes(tokens), do: tokens |> Enum.map(& &1.contract_address_hash) |> Enum.sort()
  end

  describe "changeset/2 ERC-8056 extensions and scaled_ui_state association" do
    test "casts and persists extensions" do
      address = insert(:address)

      changeset =
        Token.changeset(%Token{}, %{
          contract_address_hash: address.hash,
          type: "ERC-20",
          extensions: ["ERC-8056"]
        })

      assert changeset.valid?
      {:ok, _} = Repo.insert(changeset)

      reloaded = Repo.get_by(Token, contract_address_hash: address.hash)
      assert reloaded.extensions == ["ERC-8056"]
    end

    test "preloads scaled_ui_state side-table row" do
      address = insert(:address)

      {:ok, _} =
        Repo.insert(
          Token.changeset(%Token{}, %{contract_address_hash: address.hash, type: "ERC-20", extensions: ["ERC-8056"]})
        )

      {:ok, _} =
        Repo.insert(
          Explorer.Chain.ScaledUi.TokenState.changeset(%Explorer.Chain.ScaledUi.TokenState{}, %{
            token_contract_address_hash: address.hash,
            capability_block: 100
          })
        )

      reloaded =
        Token
        |> Repo.get_by(contract_address_hash: address.hash)
        |> Repo.preload(:scaled_ui_state)

      assert reloaded.scaled_ui_state.capability_block == 100
    end
  end
end
