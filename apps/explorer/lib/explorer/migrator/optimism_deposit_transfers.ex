defmodule Explorer.Migrator.OptimismDepositTransfers do
  @moduledoc """
    Decodes the bridge transfer of the deposits indexed before transfers were decoded at index time, from the L2
    deposit transaction: its input is the `relayMessage` calldata, and its sender the aliased L1 messenger.

    The newest deposits may have no indexed L2 transaction yet when the migration reaches them: the L2 transaction
    follows the L1 event by minutes, and a deploy restart adds its own gap. Nothing else would ever decode them, so
    they are retried as `Explorer.Migrator.OptimismBridgeTransfers.next_batch/2` describes. The migration runs only
    when `config/runtime.exs` finds the messenger and bridge addresses that
    `Explorer.Chain.Optimism.BridgeMessage.bridges/0` needs; without them it would decode nothing.
  """

  use Explorer.Migrator.FillingMigration

  import Ecto.Query

  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.{Hash, Transaction}
  alias Explorer.Chain.Optimism.{BridgeMessage, Deposit}
  alias Explorer.Migrator.{FillingMigration, OptimismBridgeTransfers}
  alias Explorer.Repo

  @migration_name "optimism_deposit_transfers"
  @default_retry_interval :timer.minutes(1)
  @default_retries 30

  @impl FillingMigration
  def migration_name, do: @migration_name

  @impl FillingMigration
  def last_unprocessed_identifiers(state) do
    OptimismBridgeTransfers.next_batch(state,
      undecoded: &undecoded/2,
      decodable: &decodable/2,
      undecoded_count: &undecoded_count/0,
      cursor: &to_string/1,
      limit: batch_size() * concurrency(),
      retries: config(:retries, @default_retries),
      retry_interval: config(:retry_interval, @default_retry_interval),
      name: @migration_name
    )
  end

  defp undecoded(cursor, limit) do
    from(d in Deposit,
      where: is_nil(d.transfer_type),
      order_by: d.l2_transaction_hash,
      select: d.l2_transaction_hash,
      limit: ^limit
    )
    |> after_hash(cursor)
    |> Repo.all(timeout: :infinity)
  end

  # Undecoded deposits whose L2 transaction is indexed by now
  defp decodable(cursor, limit) do
    from(d in Deposit,
      join: t in Transaction,
      on: t.hash == d.l2_transaction_hash,
      where: is_nil(d.transfer_type),
      order_by: d.l2_transaction_hash,
      select: d.l2_transaction_hash,
      limit: ^limit
    )
    |> after_hash(cursor)
    |> Repo.all(timeout: :infinity)
  end

  defp undecoded_count do
    Repo.aggregate(from(d in Deposit, where: is_nil(d.transfer_type)), :count, timeout: :infinity)
  end

  defp after_hash(query, nil), do: query
  defp after_hash(query, cursor), do: from(d in query, where: d.l2_transaction_hash > ^cursor)

  @impl FillingMigration
  def update_batch(l2_transaction_hashes) do
    bridges = BridgeMessage.bridges()
    mantle_mode = Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism][:mantle_mode] == true

    from(d in Deposit,
      join: t in Transaction,
      on: t.hash == d.l2_transaction_hash,
      where: d.l2_transaction_hash in ^l2_transaction_hashes and is_nil(d.transfer_type),
      select: {d.l2_transaction_hash, t.from_address_hash, t.to_address_hash, t.input, t.value}
    )
    |> Repo.all(timeout: :infinity)
    |> Enum.map(fn {hash, from, to, input, value} ->
      {[hash.bytes], BridgeMessage.decode_deposit(deposit_message(from, to, input, value, mantle_mode), bridges)}
    end)
    |> OptimismBridgeTransfers.update("op_deposits", [{"l2_transaction_hash", "bytea"}])
  end

  # The L2 transaction's value is the MNT it delivers in Mantle mode and the ETH otherwise. Mantle's ETH value is not
  # stored, but a messenger message carries both values in its calldata.
  defp deposit_message(from, to, input, value, mantle_mode) do
    value = value && Decimal.to_integer(value.value)

    %{
      from: from && Hash.to_string(from),
      to: to && Hash.to_string(to),
      data: input.bytes,
      mnt_value: if(mantle_mode, do: value),
      eth_value: if(mantle_mode, do: nil, else: value)
    }
  end

  @impl FillingMigration
  def update_cache do
    BackgroundMigrations.set_optimism_deposit_transfers_finished(true)
  end

  defp config(key, default), do: Application.get_env(:explorer, __MODULE__)[key] || default
end
