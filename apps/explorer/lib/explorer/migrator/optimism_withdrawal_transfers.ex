defmodule Explorer.Migrator.OptimismWithdrawalTransfers do
  @moduledoc """
    Decodes the bridge transfer of the withdrawals indexed before transfers were decoded at index time, from the
    `MessagePassed` log of each withdrawal. A log is matched by transaction and nonce, and must carry the withdrawal's
    own hash: several withdrawals of one transaction stay apart, and a log a reorged block left behind is not taken.

    A withdrawal whose log is not indexed yet would never be decoded otherwise (only realtime indexing runs the
    withdrawals transform, catchup does not), so it is retried as `Explorer.Migrator.OptimismBridgeTransfers.next_batch/2`
    describes. The migration runs only when `config/runtime.exs` finds the messenger and bridge addresses that
    `Explorer.Chain.Optimism.BridgeMessage.bridges/0` needs; without them it would decode nothing.
  """

  use Explorer.Migrator.FillingMigration

  import Ecto.Query

  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.Log
  alias Explorer.Chain.Optimism.{BridgeMessage, Withdrawal}
  alias Explorer.Migrator.{FillingMigration, OptimismBridgeTransfers}
  alias Explorer.Repo

  @migration_name "optimism_withdrawal_transfers"
  @default_retry_interval :timer.minutes(1)
  @default_retries 30

  @impl FillingMigration
  def migration_name, do: @migration_name

  # Nonces are kept as strings in the state: they exceed the integers JSON represents exactly
  @impl FillingMigration
  def last_unprocessed_identifiers(state) do
    OptimismBridgeTransfers.next_batch(state,
      undecoded: &undecoded/2,
      decodable: &decodable/2,
      undecoded_count: &undecoded_count/0,
      cursor: &Decimal.to_string/1,
      limit: batch_size() * concurrency(),
      retries: config(:retries, @default_retries),
      retry_interval: config(:retry_interval, @default_retry_interval),
      name: @migration_name
    )
  end

  defp undecoded(cursor, limit) do
    from(w in Withdrawal, where: is_nil(w.transfer_type), order_by: w.msg_nonce, select: w.msg_nonce, limit: ^limit)
    |> after_nonce(cursor)
    |> Repo.all(timeout: :infinity)
  end

  defp decodable(cursor, limit) do
    from(w in Withdrawal,
      where: is_nil(w.transfer_type),
      distinct: true,
      order_by: w.msg_nonce,
      select: w.msg_nonce,
      limit: ^limit
    )
    |> join_message_passed_log()
    |> after_nonce(cursor)
    |> Repo.all(timeout: :infinity)
  end

  defp undecoded_count do
    Repo.aggregate(from(w in Withdrawal, where: is_nil(w.transfer_type)), :count, timeout: :infinity)
  end

  defp after_nonce(query, nil), do: query
  defp after_nonce(query, cursor), do: from(w in query, where: w.msg_nonce > ^Decimal.new(cursor))

  # The MessagePassed log of each withdrawal: emitted by the message passer, in the withdrawal's transaction, with its
  # nonce
  defp join_message_passed_log(query) do
    event = Withdrawal.message_passed_event()
    message_passer = Withdrawal.message_passer()

    from(w in query,
      join: log in Log,
      as: :log,
      on:
        log.transaction_hash == w.l2_transaction_hash and log.address_hash == ^message_passer and
          log.first_topic == ^event and log.second_topic == fragment("numeric_to_bytea32(?)", w.msg_nonce)
    )
  end

  @impl FillingMigration
  def update_batch(nonces) do
    bridges = BridgeMessage.bridges()

    from(w in Withdrawal, where: w.msg_nonce in ^nonces and is_nil(w.transfer_type))
    |> join_message_passed_log()
    |> select([w, log: log], {w.msg_nonce, w.hash, log.third_topic, log.fourth_topic, log.data})
    |> Repo.all(timeout: :infinity)
    |> Enum.flat_map(fn {nonce, hash, sender, target, data} ->
      message = Withdrawal.parse_message_passed_data(data)

      # a reorged block can leave a log of another message under the same transaction and nonce
      if message.hash == hash.bytes do
        transfer =
          BridgeMessage.decode_withdrawal(
            %{
              from: BridgeMessage.topic_to_address(sender),
              to: BridgeMessage.topic_to_address(target),
              data: message.data,
              mnt_value: message.mnt_value,
              eth_value: message.eth_value
            },
            bridges
          )

        [{[nonce, hash.bytes], transfer}]
      else
        []
      end
    end)
    |> Enum.uniq_by(fn {[nonce, _hash], _transfer} -> nonce end)
    |> OptimismBridgeTransfers.update("op_withdrawals", [{"msg_nonce", "numeric"}, {"hash", "bytea"}])
  end

  @impl FillingMigration
  def update_cache do
    BackgroundMigrations.set_optimism_withdrawal_transfers_finished(true)
  end

  defp config(key, default), do: Application.get_env(:explorer, __MODULE__)[key] || default
end
