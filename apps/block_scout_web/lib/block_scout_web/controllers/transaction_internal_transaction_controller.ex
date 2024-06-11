defmodule BlockScoutWeb.TransactionInternalTransactionController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]
  import BlockScoutWeb.Chain, only: [paging_options: 1, next_page_params: 3, split_list_by_page: 1]
  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]
  import BlockScoutWeb.Models.GetTransactionTags, only: [get_transaction_with_addresses_tags: 2]

  alias BlockScoutWeb.{AccessHelper, Controller, InternalTransactionView, TransactionController}
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.{DenormalizationHelper, InternalTransaction}
  alias Phoenix.View
  import EthereumJSONRPC

  def index(conn, %{"transaction_id" => transaction_hash_string, "type" => "JSON"} = params) do
    with {:ok, transaction_hash} <- Chain.string_to_transaction_hash(transaction_hash_string),
         :ok <- Chain.check_transaction_exists(transaction_hash),
         {:ok, transaction} <- Chain.hash_to_transaction(transaction_hash, []),
         {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.from_address_hash), params),
         {:ok, false} <- AccessHelper.restricted_access?(to_string(transaction.to_address_hash), params) do
      full_options =
        [
          necessity_by_association: %{
            [created_contract_address: :names] => :optional,
            [from_address: :names] => :optional,
            [to_address: :names] => :optional,
            [created_contract_address: :smart_contract] => :optional,
            [from_address: :smart_contract] => :optional,
            [to_address: :smart_contract] => :optional,
            :transaction => :optional
          }
        ]
        |> DenormalizationHelper.extend_transaction_block_necessity(:optional)
        |> Keyword.merge(paging_options(params))

      internal_transactions_plus_one =
        InternalTransaction.transaction_to_internal_transactions(transaction_hash, full_options)

      {internal_transactions, next_page} = split_list_by_page(internal_transactions_plus_one)

      next_page_path =
        case next_page_params(next_page, internal_transactions, params) do
          nil ->
            nil

          next_page_params ->
            transaction_internal_transaction_path(
              conn,
              :index,
              transaction_hash,
              Map.delete(next_page_params, "type")
            )
        end

      items =
        internal_transactions
        |> Enum.map(fn internal_transaction ->
          View.render_to_string(
            InternalTransactionView,
            "_table_tile.html",
            internal_transaction: internal_transaction
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
        EthereumJSONRPC.request(%{id: 0, method: "eth_getTxStatusDetailByHash", params: [transaction_hash_string]})
        |> json_rpc(Application.get_env(:indexer, :json_rpc_named_arguments))
        |> case do
          {:ok, tx} ->
            tx["status"]

          {:error, _} ->
            nil
        end

      updated_transaction =
        case Chain.hash_to_batch(transaction_hash_string, necessity_by_association: @necessity_by_association) do
          {:error, _} ->
            transaction

          {:ok, %{batch_index: batch_index, data_commitment: data_commitment}} ->
            res = Map.put(transaction, :batch_index, batch_index)
            Map.put(res, :data_commitment, data_commitment)
        end

      updated_state_transaction =
        case Chain.block_to_state_batch(transaction.block_number, necessity_by_association: @necessity_by_association) do
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
        current_path: Controller.current_full_path(conn),
        current_user: current_user(conn),
        block_height: Chain.block_height(),
        show_token_transfers: Chain.transaction_has_token_transfers?(transaction_hash),
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
      {:restricted_access, _} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      :error ->
        unprocessable_entity(conn)

      {:error, :not_found} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)
    end
  end
end
