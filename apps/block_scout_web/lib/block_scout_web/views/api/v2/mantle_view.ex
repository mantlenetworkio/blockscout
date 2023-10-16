defmodule BlockScoutWeb.API.V2.MantleView do
  use BlockScoutWeb, :view

  import Ecto.Query, only: [from: 2]

  alias BlockScoutWeb.API.V2.Helper
  alias Explorer.{Chain, Repo}

  require Logger

  def render("mantle_deposits.json", %{
        deposits: deposits,
        next_page_params: next_page_params
      }) do
    %{
      items:
        Enum.map(deposits, fn deposit ->
          %{
            "l1_block_number" => deposit.block,
            "l2_tx_hash" => deposit.l2_hash,
            "l1_block_timestamp" => deposit.timestamp,
            "l1_tx_hash" => deposit.hash,
            "l1_tx_origin" => deposit.tx_origin,
            "l2_tx_gas_limit" => deposit.gas_limit
          }
        end),
      next_page_params: next_page_params
    }
  end

  def render("mantle_deposits.json", %{deposits: deposits}) do
    Enum.map(deposits, fn deposit ->
      %{
        "l1_block_number" => deposit.block,
        "l1_block_timestamp" => deposit.timestamp,
        "l1_tx_hash" => deposit.hash,
        "l2_tx_hash" => deposit.l2_hash
      }
    end)
  end

  def render("mantle_withdrawals.json", %{
    withdrawals: withdrawals,
    next_page_params: next_page_params,
    conn: conn
  }) do
%{
  items:
    Enum.map(withdrawals, fn w ->
      # msg_nonce =
      #   Bitwise.band(
      #     Decimal.to_integer(w.msg_nonce),
      #     0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
      #   )

      # msg_nonce_version = Bitwise.bsr(Decimal.to_integer(w.msg_nonce), 240)

      %{
        "msg_nonce_raw" => 1,
        "msg_nonce" => w.msg_nonce,
        "msg_nonce_version" => 1,
        "from" => w.from,
        "l2_tx_hash" => w.l2_transaction_hash,
        "l2_timestamp" => w.l2_timestamp,
        "status" => withdrawal_status(w.status),
        "l1_tx_hash" => w.l1_transaction_hash,
        "challenge_period_end" => w.challenge_period_end
      }
    end),
  next_page_params: next_page_params
}
end

  def render("mantle_items_count.json", %{count: count}) do
    count
  end

  defp withdrawal_status(status) do
    display_status = case status do
      "0" ->
        gettext("Waiting for relay")
      "1" ->
        gettext("Ready for Claim")
      "2" ->
        gettext("Claimed")
      _ ->
        status
    end
  end


end
