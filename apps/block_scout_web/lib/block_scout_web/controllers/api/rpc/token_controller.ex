defmodule BlockScoutWeb.API.RPC.TokenController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.API.RPC.Helper
  alias Explorer.{Chain, PagingOptions}

  alias Indexer.Fetcher.TokenInstance

  require Logger

  def gettoken(conn, params) do
    with {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param),
         {:token, {:ok, token}} <- {:token, Chain.token_from_address_hash(address_hash)} do
      render(conn, "gettoken.json", %{token: token})
    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")

      {:token, {:error, :not_found}} ->
        render(conn, :error, error: "Contract address not found")
    end
  end

  def gettokenholders(conn, params) do
    with pagination_options <- Helper.put_pagination_options(%{}, params),
         {:contractaddress_param, {:ok, contractaddress_param}} <- fetch_contractaddress(params),
         {:format, {:ok, address_hash}} <- to_address_hash(contractaddress_param) do
      options_with_defaults =
        pagination_options
        |> Map.put_new(:page_number, 0)
        |> Map.put_new(:page_size, 10)

      options = [
        paging_options: %PagingOptions{
          key: nil,
          page_number: options_with_defaults.page_number,
          page_size: options_with_defaults.page_size
        },
        api?: true
      ]

      token_holders = Chain.fetch_token_holders_from_token_hash(address_hash, options)
      render(conn, "gettokenholders.json", %{token_holders: token_holders})
    else
      {:contractaddress_param, :error} ->
        render(conn, :error, error: "Query parameter contract address is required")

      {:format, :error} ->
        render(conn, :error, error: "Invalid contract address hash")
    end
  end

  def refetchmetadata(conn, params) do
    with  {:ok, token_address_hash} <- Map.fetch(params, "addressHash"),
          {:ok, token_id_str} <- Map.fetch(params, "tokenId") do

      options = [necessity_by_association: %{[contract_address: :smart_contract] => :optional}]
      with {:ok, hash} <- Chain.string_to_address_hash(token_address_hash),
      {:ok, token} <- Chain.token_from_address_hash(hash, options),
      false <- Chain.is_erc_20_token?(token),
      {token_id, ""} <- Integer.parse(token_id_str),
      {:ok, token_instance} <-
        Chain.erc721_or_erc1155_token_instance_from_token_id_and_token_address(token_id, hash) do

        case TokenInstance.Helper.fetch_instance(token_address_hash, token_id) do
          {:ok, %{metadata: metadata}} ->
            res = %{
              "token_id" => token_id_str,
              "token_contract_address_hash" => token_address_hash,
              "metadata" => metadata,
            }
            render(conn, "refetchmetadata.json", %{result: res})
          _ ->
            res = %{
              "token_id" => token_id_str,
              "token_contract_address_hash" => token_address_hash,
            }
            render(conn, "refetchmetadata.json", %{result: res})
        end

      else
      _ ->
        render(conn, :error, error: "Invalid address hash or token ID")
      end

    else
      _ ->
        render(conn, :error, error: "Invalid address hash or token ID")
    end
  end

  defp fetch_contractaddress(params) do
    {:contractaddress_param, Map.fetch(params, "contractaddress")}
  end

  defp to_address_hash(address_hash_string) do
    {:format, Chain.string_to_address_hash(address_hash_string)}
  end
end
