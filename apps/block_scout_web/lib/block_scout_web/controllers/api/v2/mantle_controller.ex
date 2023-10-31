defmodule BlockScoutWeb.API.V2.MantleController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Chain,
    only: [
      next_page_params: 3,
      paging_options: 1,
      split_list_by_page: 1
    ]

  alias Explorer.Chain
  alias Explorer.Chain.{L1ToL2, L2ToL1}

  action_fallback(BlockScoutWeb.API.V2.FallbackController)

  require Logger


  def deposits(conn, params) do
    {deposits, next_page} =
      params
      |> paging_options()
      |> Keyword.put(:api?, true)
      |> Chain.list_mantle_deposits()
      |> split_list_by_page()

    next_page_params = next_page_params(next_page, deposits, params)

    conn
    |> put_status(200)
    |> render(:mantle_deposits, %{
      deposits: deposits,
      next_page_params: next_page_params
    })
  end

  def deposits_count(conn, _params) do
    items_count(conn, L1ToL2)
  end

  def withdrawals(conn, params) do
    {withdrawals, next_page} =
      params
      |> paging_options()
      |> Keyword.put(:api?, true)
      |> Chain.list_mantle_withdrawals()
      |> split_list_by_page()


    next_page_params = next_page_params(next_page, withdrawals, params)


    conn
    |> put_status(200)
    |> render(:mantle_withdrawals, %{
      withdrawals: withdrawals,
      next_page_params: next_page_params
    })
  end

  def withdrawals_count(conn, _params) do
    items_count(conn, L2ToL1)
  end

  def mantle_da(conn,params) do
    {mantle_da, next_page} =
      params
      |> paging_options()
      |> Keyword.put(:api?, true)
      |> Chain.list_mantle_da()
      |> split_list_by_page()


    next_page_params = next_page_params(next_page, mantle_da, params)


    conn
    |> put_status(200)
    |> render(:mantle_da, %{
      mantle_da: mantle_da,
      next_page_params: next_page_params
    })
  end

  defp items_count(conn, module) do
    count = Chain.get_table_rows_total_count(module, api?: true)

    conn
    |> put_status(200)
    |> render(:mantle_items_count, %{count: count})
  end


end
