defmodule BlockScoutWeb.AddressWriteContractView do
  use BlockScoutWeb, :view

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]
  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]

  alias BlockScoutWeb.AccessHelper
  alias BlockScoutWeb.AddressView
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.Address
  alias Explorer.ExchangeRates.Token
  alias Indexer.Fetcher.OnDemand.CoinBalance, as: CoinBalanceOnDemand

  def initial_data(conn, address_hash_string) do
    address_options = [
      necessity_by_association: %{
        :contracts_creation_internal_transaction => :optional,
        :names => :optional,
        :smart_contract => :optional,
        :token => :optional,
        :contracts_creation_transaction => :optional
      }
    ]

    custom_abi? = AddressView.has_address_custom_abi_with_write_functions?(conn, address_hash_string)

    base_params = [
      type: :regular,
      action: :write,
      custom_abi: custom_abi?,
      exchange_rate: Market.get_coin_exchange_rate(),
    ]

    with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
         {:ok, address} <- Chain.find_contract_address(address_hash, address_options, true),
         false <- is_nil(address.smart_contract),
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, %{"address_id" => address_hash_string}) do
      base_params ++
        [
          address: address,
          non_custom_abi: true,
          coin_balance_status: CoinBalanceOnDemand.trigger_fetch(address),
          counters_path: address_path(conn, :address_counters, %{"id" => Address.checksum(address_hash)}),
          tags: get_address_tags(address_hash, current_user(conn))
        ]
    else
      _ ->
        if custom_abi? do
          with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
               {:ok, address} <- Chain.find_contract_address(address_hash, address_options, false),
               {:ok, false} <-
                 AccessHelper.restricted_access?(address_hash_string, %{"address_id" => address_hash_string}) do
            base_params ++
              [
                address: address,
                non_custom_abi: false,
                coin_balance_status: CoinBalanceOnDemand.trigger_fetch(address),
                counters_path: address_path(conn, :address_counters, %{"id" => Address.checksum(address_hash)}),
                tags: get_address_tags(address_hash, current_user(conn))
              ]
          else
            _ ->
              nil
          end
        end
    end
  end
end
