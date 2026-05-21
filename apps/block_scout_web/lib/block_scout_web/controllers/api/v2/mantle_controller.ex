defmodule BlockScoutWeb.API.V2.MantleController do
  @moduledoc """
  Mantle-specific legacy API endpoints.

  These endpoints preserve compatibility with Mantle's pre-v9.3.2 frontend,
  which queries blocks and transactions by state-root-derived L2 block ranges.

  Pagination format is `{Current, Size, Total, Records}` — NOT Blockscout's
  standard `{items, next_page_params}` format.
  """

  use BlockScoutWeb, :controller

  import Ecto.Query

  alias BlockScoutWeb.API.V2.{BlockView, TransactionView}
  alias Explorer.Chain.{Block, Transaction}
  alias Explorer.Repo

  @default_page_size 50
  @max_page_size 200

  @address_preloads [:scam_badge, :names, :proxy_implementations]

  @block_preloads [
    {:miner, @address_preloads},
    :transactions,
    :rewards,
    :withdrawals,
    :uncles,
    :nephews
  ]

  @transaction_preloads [
    {:from_address, @address_preloads},
    {:to_address, @address_preloads},
    {:created_contract_address, @address_preloads},
    :block
  ]

  @doc """
  `GET /api/v2/mantle/stateroot/blocks`

  Query params:
    - `blockNumber` (required): starting L2 block number (inclusive)
    - `blockSize`   (required): number of L2 blocks covered
    - `page`        (optional, default 1): 1-based page number
    - `pageSize`    (optional, default 50, max 200)

  Returns L2 blocks in range `[blockNumber, blockNumber + blockSize)`,
  ordered by `number DESC`, wrapped in `{Current, Size, Total, Records}`.
  """
  @spec stateroot_blocks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stateroot_blocks(conn, params) do
    case parse_range_params(params) do
      {:ok, start_block, end_block, page, page_size} ->
        base_query =
          from(b in Block,
            where: b.number >= ^start_block and b.number <= ^end_block and b.consensus == true
          )

        total = Repo.replica().aggregate(base_query, :count, timeout: :infinity)
        offset = (page - 1) * page_size

        blocks =
          base_query
          |> order_by([b], desc: b.number)
          |> limit(^page_size)
          |> offset(^offset)
          |> Repo.replica().all(timeout: :infinity)
          |> Repo.replica().preload(@block_preloads)

        records = BlockView.render("blocks.json", %{blocks: blocks})

        json(conn, %{
          "Current" => page,
          "Size" => page_size,
          "Total" => total,
          "Records" => records
        })

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{"error" => reason})
    end
  end

  @doc """
  `GET /api/v2/mantle/stateroot/transactions`

  Query params: same as `stateroot_blocks`.

  Returns L2 transactions whose block is in range
  `[blockNumber, blockNumber + blockSize)`, ordered by
  `block_number DESC, index DESC`, wrapped in `{Current, Size, Total, Records}`.
  """
  @spec stateroot_transactions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stateroot_transactions(conn, params) do
    case parse_range_params(params) do
      {:ok, start_block, end_block, page, page_size} ->
        base_query =
          from(t in Transaction,
            where: t.block_number >= ^start_block and t.block_number <= ^end_block,
            inner_join: b in assoc(t, :block),
            on: b.hash == t.block_hash and b.consensus == true
          )

        total = Repo.replica().aggregate(base_query, :count, timeout: :infinity)
        offset = (page - 1) * page_size

        transactions =
          base_query
          |> order_by([t, _b], desc: t.block_number, desc: t.index)
          |> limit(^page_size)
          |> offset(^offset)
          |> Repo.replica().all(timeout: :infinity)
          |> Repo.replica().preload(@transaction_preloads)

        rendered =
          TransactionView.render("transactions.json", %{
            transactions: transactions,
            conn: conn
          })

        base_records =
          case rendered do
            %{"items" => items} -> items
            items when is_list(items) -> items
          end

        # OP v9.3.2 list view strips optimism-specific fee fields; merge them back
        # per-record so the legacy Mantle frontend receives l1_fee, operator_fee, etc.
        records =
          base_records
          |> Enum.zip(transactions)
          |> Enum.map(fn {rendered, tx} -> merge_optimism_fields(rendered, tx) end)

        json(conn, %{
          "Current" => page,
          "Size" => page_size,
          "Total" => total,
          "Records" => records
        })

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{"error" => reason})
    end
  end

  # --- Internal helpers --------------------------------------------------

  defp parse_range_params(params) do
    with {:ok, block_number} <- parse_non_negative_integer(params["blockNumber"], "blockNumber"),
         {:ok, block_size} <- parse_positive_integer(params["blockSize"], "blockSize"),
         {:ok, page} <- parse_page(params["page"]),
         {:ok, page_size} <- parse_page_size(params["pageSize"]) do
      {:ok, block_number, block_number + block_size - 1, page, page_size}
    end
  end

  defp parse_non_negative_integer(value, field) do
    case to_integer(value) do
      {:ok, n} when n >= 0 -> {:ok, n}
      {:ok, _} -> {:error, "#{field} must be >= 0"}
      :error -> {:error, "#{field} is required and must be an integer"}
    end
  end

  defp parse_positive_integer(value, field) do
    case to_integer(value) do
      {:ok, n} when n > 0 -> {:ok, n}
      {:ok, _} -> {:error, "#{field} must be > 0"}
      :error -> {:error, "#{field} is required and must be an integer"}
    end
  end

  defp parse_page(nil), do: {:ok, 1}

  defp parse_page(value) do
    case to_integer(value) do
      {:ok, n} when n >= 1 -> {:ok, n}
      _ -> {:error, "page must be >= 1"}
    end
  end

  defp parse_page_size(nil), do: {:ok, @default_page_size}

  defp parse_page_size(value) do
    case to_integer(value) do
      {:ok, n} when n >= 1 -> {:ok, min(n, @max_page_size)}
      _ -> {:error, "pageSize must be >= 1"}
    end
  end

  defp to_integer(nil), do: :error
  defp to_integer(value) when is_integer(value), do: {:ok, value}

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp to_integer(_), do: :error

  # Augment the list-view transaction JSON with OP-specific fee fields that the
  # default list view omits (they're only included in the single-tx detail view).
  @optimism_tx_fields [
    :l1_fee,
    :l1_fee_scalar,
    :l1_gas_price,
    :l1_gas_used,
    :da_footprint_gas_scalar,
    :operator_fee_scalar,
    :operator_fee_constant
  ]

  defp merge_optimism_fields(rendered, tx) do
    Enum.reduce(@optimism_tx_fields, rendered, fn field, acc ->
      case Map.get(tx, field) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(field), value)
      end
    end)
  end
end
