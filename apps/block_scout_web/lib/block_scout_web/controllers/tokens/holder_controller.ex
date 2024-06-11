defmodule BlockScoutWeb.Tokens.HolderController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]
  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]

  alias BlockScoutWeb.{AccessHelper, Controller}
  alias BlockScoutWeb.Tokens.HolderView
  alias Explorer.Chain
  alias Explorer.Chain.Address
  alias Indexer.Fetcher.OnDemand.TokenTotalSupply, as: TokenTotalSupplyOnDemand
  alias Phoenix.View

  require Logger

  import BlockScoutWeb.Chain,
    only: [
      split_list_by_page: 1,
      paging_options: 1,
      next_page_params: 3
    ]

  def index(conn, %{"token_id" => address_hash_string, "type" => "JSON"} = params) do
    if(address_hash_string == "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000") do
      {:ok, address_hash} = Chain.string_to_address_hash(address_hash_string)
      {:ok, token} = Chain.token_from_address_hash(address_hash)

      addresses =
        params
        |> paging_options()
        |> Address.list_top_addresses()

      {addresses_page, next_page} = split_list_by_page(addresses)

      next_page_path =
        case next_page_params(next_page, addresses_page, params) do
          nil ->
            nil

          next_page_params ->
            address_path(
              conn,
              :index,
              Map.delete(next_page_params, "type")
              |> Map.delete("token_id")
            )
        end

        next_page_path =
          if next_page_path != nil do
            String.replace(next_page_path, "/accounts", "/token/0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000/token-holders")
          else
            nil
          end

      items =
        addresses_page
        |> Enum.with_index(1)
        |> Enum.map(fn {{address, _tx_count}, _index} ->
          View.render_to_string(HolderView, "_native_token_balances.html",
            address: address,
            token: token,
            conn: conn
          )
        end)

      json(
        conn,
        %{
          items: items,
          next_page_path: next_page_path
        }
      )
    else
      with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
           {:ok, token} <- Chain.token_from_address_hash(address_hash),
           token_balances <- Chain.fetch_token_holders_from_token_hash(address_hash, paging_options(params)),
           {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params) do
        {token_balances_paginated, next_page} = split_list_by_page(token_balances)

        next_page_path =
          case next_page_params(next_page, token_balances_paginated, params) do
            nil ->
              nil

            next_page_params ->
              token_holder_path(conn, :index, address_hash, Map.delete(next_page_params, "type"))
          end

        token_balances_json =
          Enum.map(token_balances_paginated, fn token_balance ->
            View.render_to_string(HolderView, "_token_balances.html",
              address_hash: address_hash,
              token_balance: token_balance,
              token: token,
              conn: conn
            )
          end)

        json(conn, %{items: token_balances_json, next_page_path: next_page_path})
      else
        {:restricted_access, _} ->
          not_found(conn)

        :error ->
          not_found(conn)

        {:error, :not_found} ->
          not_found(conn)
      end
    end
  end

  def index(conn, %{"token_id" => address_hash_string} = params) do
    options = [necessity_by_association: %{[contract_address: :smart_contract] => :optional}]

    with {:ok, address_hash} <- Chain.string_to_address_hash(address_hash_string),
         {:ok, token} <- Chain.token_from_address_hash(address_hash, options),
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params) do
      render(
        conn,
        "index.html",
        current_path: Controller.current_full_path(conn),
        token: token,
        counters_path: token_path(conn, :token_counters, %{"id" => Address.checksum(address_hash)}),
        token_total_supply_status: TokenTotalSupplyOnDemand.trigger_fetch(address_hash),
        tags: get_address_tags(address_hash, current_user(conn))
      )
    else
      {:restricted_access, _} ->
        not_found(conn)

      :error ->
        not_found(conn)

      {:error, :not_found} ->
        not_found(conn)
    end
  end
end
