defmodule BlockScoutWeb.AddressReadProxyView do
  use BlockScoutWeb, :view

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]
  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]

  alias BlockScoutWeb.AccessHelper
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.Address
  alias Explorer.ExchangeRates.Token
  alias Indexer.Fetcher.CoinBalanceOnDemand

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

    with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
         {:ok, address} <- Chain.find_contract_address(address_hash, address_options, true),
         false <- is_nil(address.smart_contract),
         {:ok, false} <-
           AccessHelper.restricted_access?(address_hash_string, %{
             "address_id" => address_hash_string
           }) do
      [
        address: address,
        type: :proxy,
        action: :read,
        coin_balance_status: CoinBalanceOnDemand.trigger_fetch(address),
        exchange_rate: Market.get_coin_exchange_rate(),
        counters_path:
          address_path(conn, :address_counters, %{"id" => Address.checksum(address_hash)}),
        tags: get_address_tags(address_hash, current_user(conn))
      ]
    else
      _ ->
        nil
    end
  end
end
