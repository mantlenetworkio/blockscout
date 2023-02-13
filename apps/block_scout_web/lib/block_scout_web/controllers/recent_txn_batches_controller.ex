defmodule BlockScoutWeb.RecentTxnBatchesController do
  use BlockScoutWeb, :controller
  require Logger

  alias Explorer.{Chain, PagingOptions}
  alias Phoenix.View


  def index(conn, _params) do
    if ajax?(conn) do
      recent_txn_batches =
        Chain.recent_collated_txn_batches(
          paging_options: %PagingOptions{page_size: 6}
        )
      txn_batches =
        Enum.map(recent_txn_batches, fn txn_batch ->
          %{
            txn_batches_html:
              View.render_to_string(BlockScoutWeb.TxnBatchView, "_recent_tile.html",
                txn_batch: txn_batch,
                conn: conn,
                l1_explorer: Application.get_env(:block_scout_web, :l1_explorer_url)
              )
          }
        end)

      json(conn, %{txn_batches: txn_batches})
    else
      unprocessable_entity(conn)
    end
  end
end
