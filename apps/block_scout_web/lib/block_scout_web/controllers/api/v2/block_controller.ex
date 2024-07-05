defmodule BlockScoutWeb.API.V2.BlockController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Chain,
    only: [
      next_page_params: 3,
      next_page_params: 4,
      paging_options: 1,
      put_key_value_to_paging_options: 3,
      split_list_by_page: 1,
      parse_block_hash_or_number_param: 1
    ]

  import BlockScoutWeb.PagingHelper,
    only: [delete_parameters_from_next_page_params: 1, select_block_type: 1, type_filter_options: 1]

  import Explorer.MicroserviceInterfaces.BENS, only: [maybe_preload_ens: 1]
  import Explorer.MicroserviceInterfaces.Metadata, only: [maybe_preload_metadata: 1]

  alias BlockScoutWeb.API.V2.{TransactionView, WithdrawalView}
  alias Explorer.Chain
  alias Explorer.Chain.Arbitrum.Reader, as: ArbitrumReader
  alias Explorer.Chain.InternalTransaction

  require Logger

  case Application.compile_env(:explorer, :chain_type) do
    :ethereum ->
      @chain_type_transaction_necessity_by_association %{
        :beacon_blob_transaction => :optional
      }
      @chain_type_block_necessity_by_association %{
        [transactions: :beacon_blob_transaction] => :optional
      }

    :zksync ->
      @chain_type_transaction_necessity_by_association %{}
      @chain_type_block_necessity_by_association %{
        :zksync_batch => :optional,
        :zksync_commit_transaction => :optional,
        :zksync_prove_transaction => :optional,
        :zksync_execute_transaction => :optional
      }

    :arbitrum ->
      @chain_type_transaction_necessity_by_association %{}
      @chain_type_block_necessity_by_association %{
        :arbitrum_batch => :optional,
        :arbitrum_commitment_transaction => :optional,
        :arbitrum_confirmation_transaction => :optional
      }

    _ ->
      @chain_type_transaction_necessity_by_association %{}
      @chain_type_block_necessity_by_association %{}
  end

  @transaction_necessity_by_association [
    necessity_by_association:
      %{
        [created_contract_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
        [from_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
        [to_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
        :block => :optional
      }
      |> Map.merge(@chain_type_transaction_necessity_by_association)
  ]

  @internal_transaction_necessity_by_association [
    necessity_by_association: %{
      [created_contract_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
      [from_address: [:names, :smart_contract, :proxy_implementations]] => :optional,
      [to_address: [:names, :smart_contract, :proxy_implementations]] => :optional
    }
  ]

  @api_true [api?: true]

  @block_params [
    necessity_by_association:
      %{
        [miner: [:names, :smart_contract, :proxy_implementations]] => :optional,
        :uncles => :optional,
        :nephews => :optional,
        :rewards => :optional,
        :transactions => :optional,
        :withdrawals => :optional
      }
      |> Map.merge(@chain_type_block_necessity_by_association),
    api?: true
  ]

  action_fallback(BlockScoutWeb.API.V2.FallbackController)

  @doc """
  Function to handle GET requests to `/api/v2/blocks/:block_hash_or_number` endpoint.
  """
  @spec block(Plug.Conn.t(), map()) ::
          {:error, :not_found | {:invalid, :hash | :number}}
          | {:lost_consensus, {:error, :not_found} | {:ok, Explorer.Chain.Block.t()}}
          | Plug.Conn.t()
  def block(conn, %{"block_hash_or_number" => block_hash_or_number}) do
    with {:ok, block} <- block_param_to_block(block_hash_or_number, @block_params) do
      conn
      |> put_status(200)
      |> render(:block, %{block: block})
    end
  end

  defp fetch_block(:hash, hash, params) do
    Chain.hash_to_block(hash, params)
  end

  defp fetch_block(:number, number, params) do
    case Chain.number_to_block(number, params) do
      {:ok, _block} = ok_response ->
        ok_response

      _ ->
        {:lost_consensus, Chain.nonconsensus_block_by_number(number, @api_true)}
    end
  end

  def batch_blocks_rap(conn, params) do
    with  {:ok, blockNumber} <- Map.fetch(params, "blockNumber"),
          {:ok, blockSize} <- Map.fetch(params, "blockSize"),
          blockNumberInt <- String.to_integer(blockNumber),
          blockSizeInt <- String.to_integer(blockSize) do

          filter_options = [blocks_range: %{blockNumber: blockNumberInt, blockSize: blockSizeInt}]
          |> Keyword.merge( select_block_type(params))
          |> Keyword.merge(Chain.mantle_get_paging(params))
          |> Keyword.merge(@api_true)

          %{pagination: pagination, blocks: blocks} = Chain.get_batch_blocks_for_rap(filter_options)

          conn
          |> put_status(200)
          |> render(:blocks, %{pagination: pagination, blocks: blocks})
    else
      _ ->
        conn
        |> put_status(200)
        |> render(:blocks, %{pagination: %{
          page: 1,
          page_size: 0,
          total: 0
        }, blocks: []})
    end
  end

  def blocks_rap(conn, params) do
    filter_options = select_block_type(params)
    |> Keyword.merge(Chain.mantle_get_paging(params))
    |> Keyword.merge(@api_true)

    %{pagination: pagination, blocks: blocks} = Chain.get_blocks_for_rap(filter_options)

    conn
    |> put_status(200)
    |> render(:blocks, %{pagination: pagination, blocks: blocks})
  end

  @doc """
  Function to handle GET requests to `/api/v2/blocks` endpoint.
  """
  @spec blocks(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def blocks(conn, params) do
    full_options = select_block_type(params)

    blocks_plus_one =
      full_options
      |> Keyword.merge(paging_options(params))
      |> Keyword.merge(@api_true)
      |> Chain.list_blocks()

    {blocks, next_page} = split_list_by_page(blocks_plus_one)

    next_page_params = next_page |> next_page_params(blocks, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> render(:blocks, %{
      blocks: blocks |> maybe_preload_ens() |> maybe_preload_metadata(),
      next_page_params: next_page_params
    })
  end

  def transactions_rap(conn, %{"block_hash_or_number" => block_hash_or_number} = params) do
    with {:ok, type, value} <- parse_block_hash_or_number_param(block_hash_or_number),
         {:ok, block} <- fetch_block(type, value, @api_true) do

        full_options =
          @transaction_necessity_by_association
          |> Keyword.merge([is_index_in_asc_order: true])
          |> Keyword.merge(Chain.mantle_get_paging(params))
          |> Keyword.merge(@api_true)

        %{pagination: pagination, transactions: transactions} = Chain.block_to_transactions_rap(block.hash, full_options)

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:mantle_transactions,  %{pagination: pagination, transactions: transactions})
    end
  end

  @doc """
    Function to handle GET requests to `/api/v2/blocks/arbitrum-batch/:batch_number` endpoint.
    It renders the list of L2 blocks bound to the specified batch.
  """
  @spec arbitrum_batch(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def arbitrum_batch(conn, %{"batch_number" => batch_number} = params) do
    full_options =
      params
      |> select_block_type()
      |> Keyword.merge(paging_options(params))
      |> Keyword.merge(@api_true)

    {blocks, next_page} =
      batch_number
      |> ArbitrumReader.batch_blocks(full_options)
      |> split_list_by_page()

    next_page_params = next_page |> next_page_params(blocks, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> render(:blocks, %{
      blocks: blocks |> maybe_preload_ens() |> maybe_preload_metadata(),
      next_page_params: next_page_params
    })
  end

  @doc """
    Function to handle GET requests to `/api/v2/blocks/arbitrum-batch/:batch_number` endpoint.
    It renders the list of L2 blocks bound to the specified batch.
  """
  @spec arbitrum_batch(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def arbitrum_batch(conn, %{"batch_number" => batch_number} = params) do
    full_options =
      params
      |> select_block_type()
      |> Keyword.merge(paging_options(params))
      |> Keyword.merge(@api_true)

    {blocks, next_page} =
      batch_number
      |> ArbitrumReader.batch_blocks(full_options)
      |> split_list_by_page()

    next_page_params = next_page |> next_page_params(blocks, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> render(:blocks, %{
      blocks: blocks |> maybe_preload_ens() |> maybe_preload_metadata(),
      next_page_params: next_page_params
    })
  end

  @doc """
  Function to handle GET requests to `/api/v2/blocks/:block_hash_or_number/transactions` endpoint.
  """
  @spec transactions(Plug.Conn.t(), map()) ::
          {:error, :not_found | {:invalid, :hash | :number}}
          | {:lost_consensus, {:error, :not_found} | {:ok, Explorer.Chain.Block.t()}}
          | Plug.Conn.t()
  def transactions(conn, %{"block_hash_or_number" => block_hash_or_number} = params) do
    with {:ok, block} <- block_param_to_block(block_hash_or_number) do
      full_options =
        @transaction_necessity_by_association
        |> Keyword.merge(put_key_value_to_paging_options(paging_options(params), :is_index_in_asc_order, true))
        |> Keyword.merge(type_filter_options(params))
        |> Keyword.merge(@api_true)

      transactions_plus_one = Chain.block_to_transactions(block.hash, full_options, false)

      {transactions, next_page} = split_list_by_page(transactions_plus_one)

      next_page_params =
        next_page
        |> next_page_params(transactions, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:transactions, %{
        transactions: transactions |> maybe_preload_ens() |> maybe_preload_metadata(),
        next_page_params: next_page_params
      })
    end
  end

  @doc """
  Function to handle GET requests to `/api/v2/blocks/:block_hash_or_number/internal-transactions` endpoint.
  """
  @spec internal_transactions(Plug.Conn.t(), map()) ::
          {:error, :not_found | {:invalid, :hash | :number}}
          | {:lost_consensus, {:error, :not_found} | {:ok, Explorer.Chain.Block.t()}}
          | Plug.Conn.t()
  def internal_transactions(conn, %{"block_hash_or_number" => block_hash_or_number} = params) do
    with {:ok, block} <- block_param_to_block(block_hash_or_number) do
      full_options =
        @internal_transaction_necessity_by_association
        |> Keyword.merge(paging_options(params))
        |> Keyword.merge(@api_true)

      internal_transactions_plus_one = InternalTransaction.block_to_internal_transactions(block.hash, full_options)

      {internal_transactions, next_page} = split_list_by_page(internal_transactions_plus_one)

      next_page_params =
        next_page
        |> next_page_params(
          internal_transactions,
          delete_parameters_from_next_page_params(params),
          &InternalTransaction.internal_transaction_to_block_paging_options/1
        )

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:internal_transactions, %{
        internal_transactions: internal_transactions,
        next_page_params: next_page_params,
        block: block
      })
    end
  end

  @doc """
  Function to handle GET requests to `/api/v2/blocks/:block_hash_or_number/withdrawals` endpoint.
  """
  @spec withdrawals(Plug.Conn.t(), map()) ::
          {:error, :not_found | {:invalid, :hash | :number}}
          | {:lost_consensus, {:error, :not_found} | {:ok, Explorer.Chain.Block.t()}}
          | Plug.Conn.t()
  def withdrawals(conn, %{"block_hash_or_number" => block_hash_or_number} = params) do
    with {:ok, block} <- block_param_to_block(block_hash_or_number) do
      full_options =
        [
          necessity_by_association: %{[address: [:names, :smart_contract, :proxy_implementations]] => :optional},
          api?: true
        ]
        |> Keyword.merge(paging_options(params))

      withdrawals_plus_one = Chain.block_to_withdrawals(block.hash, full_options)
      {withdrawals, next_page} = split_list_by_page(withdrawals_plus_one)

      next_page_params = next_page |> next_page_params(withdrawals, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(WithdrawalView)
      |> render(:withdrawals, %{
        withdrawals: withdrawals |> maybe_preload_ens() |> maybe_preload_metadata(),
        next_page_params: next_page_params
      })
    end
  end

  defp block_param_to_block(block_hash_or_number, options \\ @api_true) do
    with {:ok, type, value} <- parse_block_hash_or_number_param(block_hash_or_number) do
      fetch_block(type, value, options)
    end
  end
end
