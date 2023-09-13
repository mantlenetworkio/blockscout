defmodule BlockScoutWeb.TokensERC20Controller do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Chain, only: [paging_options: 1, next_page_params: 3, split_list_by_page: 1]
  alias Explorer.Chain.{Hash}
  alias BlockScoutWeb.{Controller, TokensView}
  alias Explorer.Chain
  alias Phoenix.View
  def index(conn, %{"type" => "JSON"} = params) do
    filter =
      if Map.has_key?(params, "filter") do
        Map.get(params, "filter")
      else
        nil
      end

    paging_params =
      params
      |> paging_options()
      |> Keyword.merge([ token_type: ["ERC-20"] ])

    tokens = Chain.list_top_tokens(filter, paging_params)

    {tokens_erc20_page, next_page} = split_list_by_page(tokens)

    next_page_path =
      case next_page_params(next_page, tokens_erc20_page, params) do
        nil ->
          nil

        next_page_params ->
          tokens_erc20_path(
            conn,
            :index,
            Map.delete(next_page_params, "type")
          )
      end

    items_count_str = Map.get(params, "items_count")

    items_count =
      if items_count_str do
        {items_count, _} = Integer.parse(items_count_str)
        items_count
      else
        0
      end
    # native token holders
    native_token_holder_count = Chain.native_token_holders()

    items =
      tokens_erc20_page
      |> Enum.with_index(1)
      |> Enum.map(fn {token, index} ->
        str = get_hash_str(token.contract_address.hash)

        if(str == "0xdeaddeaddeaddeaddeaddeaddeaddeaddead0000") do
          t = Map.put(token, :new_token_holder, native_token_holder_count)
          View.render_to_string(
            TokensView,
            "_tile.html",
            token: t,
            index: items_count + index,
            conn: conn
          )
        else
          t = Map.put(token, :new_token_holder, token.holder_count)
          View.render_to_string(
            TokensView,
            "_tile.html",
            token: t,
            index: items_count + index,
            conn: conn
          )
        end


      end)

    json(
      conn,
      %{
        items: items,
        next_page_path: next_page_path
      }
    )
  end

  def get_hash_str(%Hash{} = hash) do
    to_string(hash)
  end

  def index(conn, _params) do
    render(conn, TokensView, "index.html", current_path: Controller.current_full_path(conn), type: "ERC20")
  end
end
