defmodule BlockScoutWeb.EigendaBatchController do
  use BlockScoutWeb, :controller
  require(Logger)

  import BlockScoutWeb.Chain,
    only: [
      fetch_page_number: 1,
      paging_options: 1,
      next_page_params: 3,
      update_page_parameters: 3,
      split_list_by_page: 1
    ]

  alias BlockScoutWeb.{
    AccessHelpers,
    Controller,
    TransactionInternalTransactionController,
    TransactionTokenTransferController,
    EigendaBatchView
  }
require Logger
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.Cache.Transaction, as: TransactionCache
  alias Explorer.ExchangeRates.Token
  alias Phoenix.View

  @necessity_by_association %{
    :block => :optional,
    [created_contract_address: :names] => :optional,
    [from_address: :names] => :optional,
    [to_address: :names] => :optional,
    [to_address: :smart_contract] => :optional,
    :token_transfers => :optional
  }

  {:ok, burn_address_hash} = Chain.string_to_address_hash("0x0000000000000000000000000000000000000000")
  @burn_address_hash burn_address_hash

  @default_options [
    necessity_by_association: %{
      :block => :required,
      [created_contract_address: :names] => :optional,
      [from_address: :names] => :optional,
      [to_address: :names] => :optional,
      [created_contract_address: :smart_contract] => :optional,
      [from_address: :smart_contract] => :optional,
      [to_address: :smart_contract] => :optional
    }
  ]

  def index(conn, %{"type" => "JSON"} = params) do

    options =
      @default_options
      |> Keyword.merge(paging_options(params))

    full_options =
      options
      |> Keyword.put(
        :paging_options,
        params
        |> fetch_page_number()
        |> update_page_parameters(Chain.default_page_size(), Keyword.get(options, :paging_options))
      )

    %{total_eigenda_batches_count: eigenda_batch_count, eigenda_batches: eigenda_batch_plus_one} =
      Chain.recent_collated_eigenda_batches_for_rap(full_options)
      #Logger.info("---------------=====")
      #Logger.info(eigenda_batch_plus_one)
    {eigenda_batches, next_page} =
      if fetch_page_number(params) == 1 do
        split_list_by_page(eigenda_batch_plus_one)
      else
        {eigenda_batch_plus_one, nil}
      end

    next_page_params =
      if fetch_page_number(params) == 1 do
        page_size = Chain.default_page_size()

        pages_limit = eigenda_batch_count |> Kernel./(page_size) |> Float.ceil() |> trunc()

        case next_page_params(next_page, eigenda_batches, params) do
          nil ->
            nil

          next_page_params ->
            next_page_params
            |> Map.delete("type")
            |> Map.delete("items_count")
            |> Map.put("pages_limit", pages_limit)
            |> Map.put("page_size", page_size)
            |> Map.put("page_number", 1)
        end
      else
        Map.delete(params, "type")
      end

    json(
      conn,
      %{
        items:
          Enum.map(eigenda_batches, fn eigenda_batch ->
            View.render_to_string(
              EigendaBatchView,
              "_tile.html",
              eigenda_batch: eigenda_batch,
              conn: conn
            )
          end),
        next_page_params: next_page_params
      }
    )
  end

  def index(conn, _params) do
    transaction_estimated_count = TransactionCache.estimated_count()

    render(
      conn,
      "index.html",
      current_path: Controller.current_full_path(conn),
      transaction_estimated_count: transaction_estimated_count
    )
  end

  def show(conn, %{"da_hash" => da_hash}) do
    %{da_batch: da_batch} = Chain.da_batch_detail(da_hash);
    render(
          conn,
          "overview.html",
          da_batch: da_batch,
          l1_explorer: Application.get_env(:block_scout_web, :l1_explorer_url)
        )
  end

end
