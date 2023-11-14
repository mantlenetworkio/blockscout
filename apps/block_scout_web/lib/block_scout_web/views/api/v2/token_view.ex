defmodule BlockScoutWeb.API.V2.TokenView do

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]
  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]

  alias BlockScoutWeb.API.V2.Helper
  alias BlockScoutWeb.NFTHelper
  alias Explorer.Chain
  alias Explorer.Chain.Address

  require Logger

  @api_true [api?: true]

  def render("token.json", %{token: token, conn: conn}) do
    %{
      "address" => Address.checksum(token.contract_address_hash),
      "symbol" => token.symbol,
      "name" => token.name,
      "decimals" => token.decimals,
      "type" => token.type,
      "holders" => token.holder_count && to_string(token.holder_count),
      "exchange_rate" => exchange_rate(token),
      "total_supply" => token.total_supply,
      "icon_url" => token.icon_url,
      "circulating_market_cap" => token.circulating_market_cap,
      "tags" =>  getTags(conn,token)
    }
  end

  defp getTags(conn, token) do
    %{
      common_tags: public_tags,
      personal_tags: private_tags,
      watchlist_names: watchlist_names
    } = get_address_tags(token.contract_address_hash, current_user(conn))

    %{
      "private_tags" => private_tags,
      "watchlist_names" => watchlist_names,
      "public_tags" => public_tags
    }
  end

  def render("token.json", %{token: token}) do
    %{
      "address" => Address.checksum(token.contract_address_hash),
      "symbol" => token.symbol,
      "name" => token.name,
      "decimals" => token.decimals,
      "type" => token.type,
      "holders" => token.holder_count && to_string(token.holder_count),
      "exchange_rate" => exchange_rate(token),
      "total_supply" => token.total_supply,
      "icon_url" => token.icon_url,
      "circulating_market_cap" => token.circulating_market_cap
    }
  end

  def render("token_balances.json", %{
        token_balances: token_balances,
        next_page_params: next_page_params,
        token: token
      }) do
    %{
      "items" => Enum.map(token_balances, &prepare_token_balance(&1, token)),
      "next_page_params" => next_page_params
    }
  end

  def render("token_instance.json", %{token_instance: token_instance, token: token}) do
    prepare_token_instance(token_instance, token)
  end

  def render("tokens.json", %{tokens: tokens, next_page_params: next_page_params, conn: conn}) do
    %{"items" => Enum.map(tokens, &render("token.json", %{token: &1, conn: conn})), "next_page_params" => next_page_params}
  end

  def render("token_instances.json", %{
        token_instances: token_instances,
        next_page_params: next_page_params,
        token: token
      }) do
    %{
      "items" => Enum.map(token_instances, &render("token_instance.json", %{token_instance: &1, token: token})),
      "next_page_params" => next_page_params
    }
  end

  def exchange_rate(%{fiat_value: fiat_value}) when not is_nil(fiat_value), do: to_string(fiat_value)
  def exchange_rate(_), do: nil

  def prepare_token_balance(token_balance, token) do
    %{
      "address" => Helper.address_with_info(nil, token_balance.address, token_balance.address_hash, false),
      "value" => token_balance.value,
      "token_id" => token_balance.token_id,
      "token" => render("token.json", %{token: token})
    }
  end

  def prepare_token_instance(instance, token) do
    is_unique =
      not (token.type == "ERC-1155") or
        Chain.token_id_1155_is_unique?(token.contract_address_hash, instance.token_id, @api_true)

    %{
      "id" => instance.token_id,
      "metadata" => instance.metadata,
      "owner" =>
        if(is_unique, do: instance.owner && Helper.address_with_info(nil, instance.owner, instance.owner.hash, false)),
      "token" => render("token.json", %{token: token}),
      "external_app_url" => NFTHelper.external_url(instance),
      "animation_url" => instance.metadata && NFTHelper.retrieve_image(instance.metadata["animation_url"]),
      "image_url" => instance.metadata && NFTHelper.get_media_src(instance.metadata, false),
      "is_unique" => is_unique
    }
  end
end
