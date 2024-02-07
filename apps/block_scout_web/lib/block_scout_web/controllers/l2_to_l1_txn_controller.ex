defmodule BlockScoutWeb.L2ToL1TxnController do
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
    AccessHelper,
    Controller,
    TransactionInternalTransactionController,
    TransactionTokenTransferController,
    L2ToL1TxnView
  }

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

    %{total_l2_to_l1_count: l2_to_l1_count, l2_to_l1: l2_to_l1_plus_one} =
      Chain.recent_collated_l2_to_l1_for_rap(full_options)

    {l2_to_l1, next_page} =
      if fetch_page_number(params) == 1 do
        split_list_by_page(l2_to_l1_plus_one)
      else
        {l2_to_l1_plus_one, nil}
      end

    next_page_params =
      if fetch_page_number(params) == 1 do
        page_size = Chain.default_page_size()

        pages_limit = l2_to_l1_count |> Kernel./(page_size) |> Float.ceil() |> trunc()

        case next_page_params(next_page, l2_to_l1, params) do
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
          Enum.map(l2_to_l1, fn l ->
            display_status = case l.status do
              "0" ->
                gettext("Waiting for relay")
              "1" ->
                gettext("Ready for Claim")
              "2" ->
                gettext("Claimed")
              _ ->
                l.status
            end

            updated_l2_to_l1 = Map.put(l, :display_status, display_status)

            display_status_tooltip = case l.status do
              "0" ->
                gettext("Withdrawn on L2 but not ready for claim on L1")
              "1" ->
                gettext("Ready for claim on L1")
              "2" ->
                gettext("Withdrawal has been claimed on L1")
              _ ->
                l.status
            end
            l2_to_l1_data = Map.put(updated_l2_to_l1, :display_status_tooltip, display_status_tooltip)
            View.render_to_string(
              L2ToL1TxnView,
              "_tile.html",
              l2_to_l1: l2_to_l1_data,
              conn: conn,
              l1_explorer: Application.get_env(:block_scout_web, :l1_explorer_url)
            )
          end),
        next_page_params: next_page_params
      }
    )
  end

  def index(conn, _params) do

    render(
      conn,
      "index.html",
      current_path: Controller.current_full_path(conn),
    )
  end

  def show(conn, %{"id" => transaction_hash_string, "type" => "JSON"}) do
    case Chain.string_to_transaction_hash(transaction_hash_string) do
      {:ok, transaction_hash} ->
        if Chain.transaction_has_token_transfers?(transaction_hash) do
          TransactionTokenTransferController.index(conn, %{
            "transaction_id" => transaction_hash_string,
            "type" => "JSON"
          })
        else
          TransactionInternalTransactionController.index(conn, %{
            "transaction_id" => transaction_hash_string,
            "type" => "JSON"
          })
        end

      :error ->
        set_not_found_view(conn, transaction_hash_string)
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, transaction_hash} <- Chain.string_to_transaction_hash(id),
         :ok <- Chain.check_transaction_exists(transaction_hash) do
      if Chain.transaction_has_token_transfers?(transaction_hash) do
        with {:ok, transaction} <-
               Chain.hash_to_transaction(
                 transaction_hash,
                 necessity_by_association: @necessity_by_association
               ),
             {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.from_address_hash), params),
             {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.to_address_hash), params) do
          render(
            conn,
            "show_token_transfers.html",
            exchange_rate: Market.get_coin_exchange_rate(),
            block_height: Chain.block_height(),
            current_path: Controller.current_full_path(conn),
            show_token_transfers: true,
            transaction: transaction
          )
        else
          :not_found ->
            set_not_found_view(conn, id)

          :error ->
            set_invalid_view(conn, id)

          {:error, :not_found} ->
            set_not_found_view(conn, id)

          {:restricted_access, _} ->
            set_not_found_view(conn, id)
        end
      else
        with {:ok, transaction} <-
               Chain.hash_to_transaction(
                 transaction_hash,
                 necessity_by_association: @necessity_by_association
               ),
             {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.from_address_hash), params),
             {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.to_address_hash), params) do
          render(
            conn,
            "show_internal_transactions.html",
            exchange_rate: Market.get_coin_exchange_rate(),
            current_path: Controller.current_full_path(conn),
            block_height: Chain.block_height(),
            show_token_transfers: Chain.transaction_has_token_transfers?(transaction_hash),
            transaction: transaction
          )
        else
          :not_found ->
            set_not_found_view(conn, id)

          :error ->
            set_invalid_view(conn, id)

          {:error, :not_found} ->
            set_not_found_view(conn, id)

          {:restricted_access, _} ->
            set_not_found_view(conn, id)
        end
      end
    else
      :error ->
        set_invalid_view(conn, id)

      :not_found ->
        set_not_found_view(conn, id)
    end
  end

  def set_not_found_view(conn, transaction_hash_string) do
    conn
    |> put_status(404)
    |> put_view(TransactionView)
    |> render("not_found.html", transaction_hash: transaction_hash_string)
  end

  def set_invalid_view(conn, transaction_hash_string) do
    conn
    |> put_status(422)
    |> put_view(TransactionView)
    |> render("invalid.html", transaction_hash: transaction_hash_string)
  end
end
