defmodule BlockScoutWeb.TransactionRawTraceController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]
  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]
  import BlockScoutWeb.Models.GetTransactionTags, only: [get_transaction_with_addresses_tags: 2]
  import EthereumJSONRPC

  alias BlockScoutWeb.{AccessHelper, TransactionController}
  alias EthereumJSONRPC
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.InternalTransaction
  alias Indexer.Fetcher.OnDemand.FirstTrace, as: FirstTraceOnDemand

  def index(conn, %{"transaction_id" => hash_string} = params) do
    with {:ok, hash} <- Chain.string_to_transaction_hash(hash_string),
         {:ok, transaction} <-
           Chain.hash_to_transaction(
             hash,
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
      if is_nil(transaction.block_number) do
        render_raw_trace(conn, [], transaction, hash, hash_string)
      else
        internal_transactions = InternalTransaction.all_transaction_to_internal_transactions(hash)

        first_trace_exists =
          Enum.find_index(internal_transactions, fn trace ->
            trace.index == 0
          end)

        if !first_trace_exists do
          FirstTraceOnDemand.trigger_fetch(transaction)
        end

        render_raw_trace(conn, internal_transactions, transaction, hash, hash_string)
      end
    else
      {:restricted_access, _} ->
        TransactionController.set_not_found_view(conn, hash_string)

      :error ->
        unprocessable_entity(conn)

      {:error, :not_found} ->
        TransactionController.set_not_found_view(conn, hash_string)
    end
  end

  defp render_raw_trace(conn, internal_transactions, transaction, hash, transaction_hash_string) do
    tx_status = EthereumJSONRPC.request(%{id: 0, method: "eth_getTxStatusDetailByHash", params: [transaction_hash_string]})
          |> json_rpc(Application.get_env(:indexer, :json_rpc_named_arguments))
          |> case do
            {:ok, tx}  ->
              tx["status"]
            {:error, _} ->
              nil
          end
          updated_transaction = case Chain.hash_to_batch(transaction_hash_string,necessity_by_association: @necessity_by_association) do
            {:error, _} ->
              transaction
            {:ok, %{batch_index: batch_index, data_commitment: data_commitment}} ->
              res = Map.put(transaction, :batch_index, batch_index)
              Map.put(res, :data_commitment, data_commitment)
          end
          updated_state_transaction = case Chain.block_to_state_batch(transaction.block_number,necessity_by_association: @necessity_by_association) do
            {:error, _} ->
              updated_transaction
            {:ok, %{batch_index: batch_index, submission_tx_hash: submission_tx_hash}} ->
              res = Map.put(updated_transaction, :state_batch_index, batch_index)
              Map.put(res, :submission_tx_hash, submission_tx_hash)
          end

          updated_display_tx_status_state_transaction = if tx_status == nil, do: updated_state_transaction, else: Map.put(updated_state_transaction, :tx_status, tx_status)
          updated_token_price_transaction = case Chain.get_real_time_token_price() do
            {:error, _} ->
              updated_display_tx_status_state_transaction
            {:ok, %{mnt_to_usd: mnt_to_usd}} ->
              Map.put(updated_display_tx_status_state_transaction, :real_time_price, mnt_to_usd)
          end

          updated_token_price_history_transaction = case Chain.get_token_price_history(updated_token_price_transaction.block) do
            {:error, _} ->
              updated_token_price_transaction
            {:ok, %{mnt_to_usd: mnt_to_usd}} ->
              Map.put(updated_token_price_transaction, :token_price_history, mnt_to_usd)
            end
    render(
      conn,
      "index.html",
      exchange_rate: Market.get_coin_exchange_rate(),
      internal_transactions: internal_transactions,
      block_height: Chain.block_height(),
      current_user: current_user(conn),
      show_token_transfers: Chain.transaction_has_token_transfers?(hash),
      transaction: updated_token_price_history_transaction,
      from_tags: get_address_tags(transaction.from_address_hash, current_user(conn)),
      to_tags: get_address_tags(transaction.to_address_hash, current_user(conn)),
      tx_tags:
        get_transaction_with_addresses_tags(
          transaction,
          current_user(conn)
        )
    )
  end
end
