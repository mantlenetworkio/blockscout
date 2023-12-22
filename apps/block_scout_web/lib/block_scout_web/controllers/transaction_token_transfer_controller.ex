defmodule BlockScoutWeb.TransactionTokenTransferController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]

  import BlockScoutWeb.Chain,
    only: [paging_options: 1, next_page_params: 3, split_list_by_page: 1]

  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]
  import BlockScoutWeb.Models.GetTransactionTags, only: [get_transaction_with_addresses_tags: 2]
  import Explorer.Chain.SmartContract, only: [burn_address_hash_string: 0]

  alias BlockScoutWeb.{AccessHelper, Controller, TransactionController, TransactionTokenTransferView}
  alias Explorer.{Chain, Market}
  alias Phoenix.View
  import EthereumJSONRPC
  require Logger

  {:ok, burn_address_hash} = Chain.string_to_address_hash(burn_address_hash_string())
  @burn_address_hash burn_address_hash

  def index(conn, %{"transaction_id" => transaction_hash_string, "type" => "JSON"} = params) do
    with {:ok, transaction_hash} <- Chain.string_to_transaction_hash(transaction_hash_string),
         :ok <- Chain.check_transaction_exists(transaction_hash),
         {:ok, transaction} <-
           Chain.hash_to_transaction(
             transaction_hash,
             []
           ),
         {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.from_address_hash), params),
         {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.to_address_hash), params) do
      full_options =
        Keyword.merge(
          [
            necessity_by_association: %{
              :block => :optional,
              [from_address: :smart_contract] => :optional,
              [to_address: :smart_contract] => :optional,
              [from_address: :names] => :optional,
              [to_address: :names] => :optional,
              from_address: :required,
              to_address: :required
            }
          ],
          paging_options(params)
        )

      token_transfers_plus_one =
        Chain.transaction_to_token_transfers(transaction_hash, full_options)

      {token_transfers, next_page} = split_list_by_page(token_transfers_plus_one)

      next_page_url =
        case next_page_params(next_page, token_transfers, params) do
          nil ->
            nil

          next_page_params ->
            transaction_token_transfer_path(
              conn,
              :index,
              transaction_hash,
              Map.delete(next_page_params, "type")
            )
        end

      # transaction2 =
      #   Chain.hash_to_transaction(
      #     transaction_hash,
      #     necessity_by_association: %{
      #       [created_contract_address: :names] => :optional,
      #       [from_address: :names] => :optional,
      #       [to_address: :names] => :optional,
      #       [created_contract_address: :smart_contract] => :optional,
      #       [from_address: :smart_contract] => :optional,
      #       [to_address: :smart_contract] => :optional,
      #       [token_transfers: :token] => :optional,
      #       [token_transfers: :to_address] => :optional,
      #       [token_transfers: :from_address] => :optional,
      #       [token_transfers: :token_contract_address] => :optional,
      #       :block => :required
      #     }
      #   )

      items =
        token_transfers
        |> Enum.map(fn transfer ->

          View.render_to_string(
            TransactionTokenTransferView,
            "_token_transfer_table.html",
            token_transfer: transfer,
            burn_address_hash: @burn_address_hash,
            conn: conn
          )
        end)

      json(
        conn,
        %{
          items: items,
          next_page_path: next_page_url
        }
      )
    else
      {:restricted_access, _} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      :error ->
        unprocessable_entity(conn)

      {:error, :not_found} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      :not_found ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)
    end
  end

  def index(conn, %{"transaction_id" => transaction_hash_string} = params) do
    with {:ok, transaction_hash} <- Chain.string_to_transaction_hash(transaction_hash_string),
         {:ok, transaction} <-
           Chain.hash_to_transaction(
             transaction_hash,
             necessity_by_association: %{
               :block => :optional,
               [created_contract_address: :names] => :optional,
               [from_address: :names] => :optional,
               [to_address: :names] => :optional,
               [to_address: :smart_contract] => :optional,
               :token_transfers => :optional
             }
           ),
         {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.from_address_hash), params),
         {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.to_address_hash), params) do
      tx_status =
        EthereumJSONRPC.request(%{
          id: 0,
          method: "eth_getTxStatusDetailByHash",
          params: [transaction_hash_string]
        })
        |> json_rpc(Application.get_env(:indexer, :json_rpc_named_arguments))
        |> case do
          {:ok, tx} ->
            tx["status"]

          {:error, _} ->
            nil
        end

      updated_transaction =
        case Chain.hash_to_batch(transaction_hash_string,
               necessity_by_association: @necessity_by_association
             ) do
          {:error, _} ->
            transaction

          {:ok, %{batch_index: batch_index, data_commitment: data_commitment}} ->
            res = Map.put(transaction, :batch_index, batch_index)
            Map.put(res, :data_commitment, data_commitment)
        end

      updated_state_transaction =
        case Chain.block_to_state_batch(transaction.block_number,
               necessity_by_association: @necessity_by_association
             ) do
          {:error, _} ->
            updated_transaction

          {:ok, %{batch_index: batch_index, submission_tx_hash: submission_tx_hash}} ->
            res = Map.put(updated_transaction, :state_batch_index, batch_index)
            Map.put(res, :submission_tx_hash, submission_tx_hash)
        end

      updated_display_tx_status_state_transaction =
        if tx_status == nil,
          do: updated_state_transaction,
          else: Map.put(updated_state_transaction, :tx_status, tx_status)

      updated_token_price_transaction =
        case Chain.get_real_time_token_price() do
          {:error, _} ->
            updated_display_tx_status_state_transaction

          {:ok, %{mnt_to_usd: mnt_to_usd}} ->
            Map.put(updated_display_tx_status_state_transaction, :real_time_price, mnt_to_usd)
        end

      updated_token_price_history_transaction =
        case Chain.get_token_price_history(updated_token_price_transaction.block) do
          {:error, _} ->
            updated_token_price_transaction

          {:ok, %{mnt_to_usd: mnt_to_usd}} ->
            Map.put(updated_token_price_transaction, :token_price_history, mnt_to_usd)
        end

      render(
        conn,
        "index.html",
        exchange_rate: Market.get_coin_exchange_rate(),
        block_height: Chain.block_height(),
        current_path: Controller.current_full_path(conn),
        current_user: current_user(conn),
        show_token_transfers: true,
        transaction: updated_token_price_history_transaction,
        from_tags: get_address_tags(transaction.from_address_hash, current_user(conn)),
        to_tags: get_address_tags(transaction.to_address_hash, current_user(conn)),
        tx_tags:
          get_transaction_with_addresses_tags(
            transaction,
            current_user(conn)
          )
      )
    else
      :not_found ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      :error ->
        unprocessable_entity(conn)

      {:error, :not_found} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      {:restricted_access, _} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)
    end
  end
end
