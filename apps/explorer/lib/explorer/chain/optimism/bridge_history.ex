defmodule Explorer.Chain.Optimism.BridgeHistory do
  @moduledoc """
    Reads the bridge history of an address: the deposits and withdrawals it sent or received through the bridge, with
    their statuses, as the official bridge's history page and its transaction tracking need them.

    Every page is a bounded read. The address's rows come from one index range per side (sender and recipient) and
    table, each limited to the page size, and the page is cut to its size before anything else is read for it. Its
    statuses then come from a constant number of queries, whatever the page size.

    On Mantle mainnet and Sepolia the page also holds the v1 (pre-Bedrock) messages of the address
    (`Explorer.Chain.Optimism.LegacyBridgeTransfer`, `is_legacy: true`), once their backfill is validated against the
    chain. v1 withdrawals have version 0 nonces, below every v2 nonce, so they follow the v2 ones; v1 deposits sit in
    L1 blocks older than any v2 deposit.
  """

  import Ecto.Query
  import Explorer.Chain, only: [select_repo: 1]

  alias Explorer.Application.Constants
  alias Explorer.Chain.{Block, Data, Hash, Log, Transaction}

  alias Explorer.Chain.Optimism.{
    BridgeMessage,
    Deposit,
    LegacyBridgeTransfer,
    MessageRelay,
    Withdrawal,
    WithdrawalEvent
  }

  @deposit_pending "Pending"
  @deposit_failed "Failed"
  @deposit_relayed "Relayed"
  @relay_failed "Relay failed"

  @transfer_address_columns [:transfer_from_address_hash, :transfer_to_address_hash]

  @doc """
    Returns a page of the deposits `address_hash` sent or received through the bridge, newest first, pending and
    failed ones included.

    ## Options
    - `:limit` - The page size.
    - `:transaction_hash` - Only the deposits of this L1 transaction.
    - `:paging_key` - The `paging_key` of the last deposit of the previous page.
    - `:api?` - Whether to read from the replica.

    ## Returns
    - Maps with the deposit and its bridge transfer, `status` (`Pending` until the L2 transaction and its relay are
      indexed, `Failed`, `Relayed`, `Relay failed`), `relay_transaction_hash`, for a failed relay what a replay needs
      (`msg_data`, the L2 transaction input, and `msg_target_address_hash`, the L2CrossDomainMessenger), `is_legacy`,
      and `paging_key`: `{l1_block_number, tie}`, the tie being the L2 transaction hash of a v2 deposit and the v0
      message hash of a v1 one.
    - A v1 deposit's L2 transaction is the one that relayed it, so it has none until it is relayed. It carries no
      replay payload: the v2 messenger cannot replay a v0 message.
  """
  @spec deposits(Hash.Address.t(), keyword()) :: [map()]
  def deposits(address_hash, options) do
    rows =
      address_hash
      |> deposits_query(legacy_served?(options), options)
      |> select_repo(options).all(timeout: :infinity)

    relays = relay_summaries(Enum.map(rows, & &1.message_hash), :l2, options)

    rows
    |> Enum.map(fn row ->
      relay = Map.get(relays, row.message_hash)

      row
      |> Map.drop([:l2_transaction_status, :tie])
      |> Map.merge(%{
        l2_transaction_hash: if(row.is_legacy, do: relay[:transaction_hash], else: row.l2_transaction_hash),
        status: deposit_status(row, relay),
        relay_transaction_hash: relay[:transaction_hash],
        msg_data: nil,
        msg_target_address_hash: nil,
        paging_key: {row.l1_block_number, row.tie}
      })
    end)
    |> with_deposit_replay_payloads(options)
  end

  @doc """
    Returns a page of the withdrawals `address_hash` sent or received through the bridge, newest first.

    ## Options
    - `:limit` - The page size.
    - `:transaction_hash` - Only the withdrawals of this L2 transaction.
    - `:paging_key` - The nonce of the last withdrawal of the previous page.
    - `:api?` - Whether to read from the replica.

    ## Returns
    - Maps with the withdrawal and its bridge transfer, `status`, `challenge_period_end` and `prove_transaction_hash`
      (see `Explorer.Chain.Optimism.Withdrawal.with_statuses/2`), the finalizing `l1_transaction_hash`,
      `relay_transaction_hash`, for a failed relay what a replay needs (`msg_data`, `msg_target_address_hash` and
      `msg_gas_limit` of the `MessagePassed` event), and `is_legacy`.
    - A v1 withdrawal relayed in the v1 era is `Relayed`, its L1 relay being its finalization. Any other follows the
      v2 portal and messenger under the identity the migration gave it: its `hash` and `message_hash` are the migrated
      ones, and a failed relay is replayed with the migrated message.
  """
  @spec withdrawals(Hash.Address.t(), keyword()) :: [map()]
  def withdrawals(address_hash, options) do
    rows =
      address_hash
      |> withdrawals_query(legacy_served?(options), options)
      |> select_repo(options).all(timeout: :infinity)

    relays = relay_summaries(Enum.flat_map(rows, &[&1.message_hash, &1.legacy_message_hash]), :l1, options)

    rows
    |> Enum.map(&with_relay(&1, relays))
    |> Withdrawal.with_statuses(options)
    |> with_withdrawal_replay_payloads(options)
    |> Enum.map(&Map.drop(&1, [:relay_status, :legacy_message_hash, :migrated_msg_data, :migrated_gas_limit]))
  end

  # The v1 history is served only once its backfill is validated against the chain
  defp legacy_served?(options) do
    Constants.get_constant_value(LegacyBridgeTransfer.validated_constant(), options) == "true"
  end

  defp relay_summaries(message_hashes, chain, options) do
    message_hashes
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> MessageRelay.summaries(chain, options)
  end

  # The page of deposits is cut to its size in a subquery, so that only its rows are joined to their L2 transactions
  defp deposits_query(address_hash, legacy?, options) do
    from(d in subquery(deposits_page(address_hash, legacy?, options)),
      left_join: t in Transaction,
      on: t.hash == d.l2_transaction_hash,
      order_by: [desc: d.l1_block_number, desc: d.tie],
      select: %{
        l1_transaction_hash: d.l1_transaction_hash,
        l1_block_number: d.l1_block_number,
        l1_block_timestamp: d.l1_block_timestamp,
        l2_transaction_hash: d.l2_transaction_hash,
        l2_transaction_status: t.status,
        message_hash: d.message_hash,
        transfer_type: d.transfer_type,
        transfer_from_address_hash: d.transfer_from_address_hash,
        transfer_to_address_hash: d.transfer_to_address_hash,
        l1_token_address_hash: d.l1_token_address_hash,
        l2_token_address_hash: d.l2_token_address_hash,
        transfer_amount: d.transfer_amount,
        mnt_value: d.mnt_value,
        eth_value: d.eth_value,
        is_legacy: d.is_legacy,
        tie: d.tie
      }
    )
  end

  defp deposits_page(address_hash, legacy?, options) do
    sides =
      for(filter <- side_filters(address_hash, :l1_transaction_hash, options), do: deposit_side(filter, options)) ++
        if legacy?,
          do:
            for(
              filter <- side_filters(address_hash, :transaction_hash, options),
              do: legacy_deposit_side(filter, options)
            ),
          else: []

    from(d in subquery(union_sides(sides)),
      order_by: [desc: d.l1_block_number, desc: d.tie],
      limit: ^Keyword.fetch!(options, :limit)
    )
  end

  defp deposit_side(filter, options) do
    from(d in Deposit,
      order_by: [desc: d.l1_block_number, desc: d.l2_transaction_hash],
      limit: ^Keyword.fetch!(options, :limit),
      # the columns of every deposit side, in one order: UNION matches them by position
      select: %{
        l1_block_number: d.l1_block_number,
        tie: d.l2_transaction_hash,
        l1_transaction_hash: d.l1_transaction_hash,
        l1_block_timestamp: d.l1_block_timestamp,
        l2_transaction_hash: d.l2_transaction_hash,
        message_hash: d.message_hash,
        transfer_type: d.transfer_type,
        transfer_from_address_hash: d.transfer_from_address_hash,
        transfer_to_address_hash: d.transfer_to_address_hash,
        l1_token_address_hash: d.l1_token_address_hash,
        l2_token_address_hash: d.l2_token_address_hash,
        transfer_amount: d.transfer_amount,
        mnt_value: d.mnt_value,
        eth_value: d.eth_value,
        is_legacy: false
      }
    )
    |> filter_side(filter)
    |> page_by_block(:l1_block_number, :l2_transaction_hash, Keyword.get(options, :paging_key))
  end

  defp legacy_deposit_side(filter, options) do
    from(t in LegacyBridgeTransfer,
      # a literal, so that the partial indexes of the direction serve any plan, generic ones included
      where: fragment("? = 'deposit'", t.direction),
      order_by: [desc: t.block_number, desc: t.message_hash],
      limit: ^Keyword.fetch!(options, :limit),
      select: %{
        l1_block_number: t.block_number,
        tie: t.message_hash,
        l1_transaction_hash: t.transaction_hash,
        l1_block_timestamp: t.timestamp,
        l2_transaction_hash: type(^nil, Hash.Full),
        message_hash: t.message_hash,
        transfer_type: t.transfer_type,
        transfer_from_address_hash: t.transfer_from_address_hash,
        transfer_to_address_hash: t.transfer_to_address_hash,
        l1_token_address_hash: t.l1_token_address_hash,
        l2_token_address_hash: t.l2_token_address_hash,
        transfer_amount: t.transfer_amount,
        mnt_value: type(^nil, :decimal),
        eth_value: type(^nil, :decimal),
        is_legacy: true
      }
    )
    |> filter_side(filter)
    |> page_by_block(:block_number, :message_hash, Keyword.get(options, :paging_key))
  end

  # One index range per side of the address, or the rows of one transaction through its own index
  defp side_filters(address_hash, transaction_column, options) do
    case Keyword.get(options, :transaction_hash) do
      nil -> Enum.map(@transfer_address_columns, &{:address, &1, address_hash})
      transaction_hash -> [{:transaction, transaction_column, transaction_hash, address_hash}]
    end
  end

  defp filter_side(query, {:address, column, address_hash}),
    do: where(query, [r], field(r, ^column) == ^address_hash)

  defp filter_side(query, {:transaction, column, transaction_hash, address_hash}) do
    where(
      query,
      [r],
      field(r, ^column) == ^transaction_hash and
        (r.transfer_from_address_hash == ^address_hash or r.transfer_to_address_hash == ^address_hash)
    )
  end

  # Each side keeps its order and limit in its own subquery. UNION also drops the second copy of an item sent to
  # oneself.
  defp union_sides([first | rest]) do
    Enum.reduce(rest, from(s in subquery(first)), fn side, union -> union(union, ^from(s in subquery(side))) end)
  end

  defp page_by_block(query, _block_column, _tie_column, nil), do: query

  # A row comparison lets Postgres start the index range right at the page key
  defp page_by_block(query, block_column, tie_column, {block_number, tie}) do
    where(
      query,
      [r],
      fragment(
        "(?, ?) < (?, ?)",
        field(r, ^block_column),
        field(r, ^tie_column),
        type(^block_number, :integer),
        type(^tie, Hash.Full)
      )
    )
  end

  # A v1 deposit's status is its relay by the legacy L2 messenger, under its v0 hash.
  defp deposit_status(%{is_legacy: true}, %{status: :relayed}), do: @deposit_relayed
  defp deposit_status(%{is_legacy: true}, %{status: :failed}), do: @relay_failed
  defp deposit_status(%{is_legacy: true}, nil), do: @deposit_pending

  # Pending: the L2 transaction is not indexed, or the relay of a messenger message is not indexed yet. Failed: the L2
  # transaction reverted. Relayed / Relay failed: the L2 messenger's result, a replay winning over earlier failures. A
  # deposit that is not a messenger message is Relayed once its L2 transaction succeeded.
  defp deposit_status(%{l2_transaction_status: nil}, _relay), do: @deposit_pending
  defp deposit_status(%{l2_transaction_status: :error}, _relay), do: @deposit_failed
  defp deposit_status(_row, %{status: :relayed}), do: @deposit_relayed
  defp deposit_status(_row, %{status: :failed}), do: @relay_failed
  defp deposit_status(%{message_hash: nil}, _relay), do: @deposit_relayed
  defp deposit_status(_row, nil), do: @deposit_pending

  # A replay of a failed L2 relay calls the L2CrossDomainMessenger with the deposit transaction's input. One query, for
  # the relay-failed v2 deposits of the page only.
  defp with_deposit_replay_payloads(deposits, options) do
    case for(%{status: @relay_failed, is_legacy: false} = deposit <- deposits, do: deposit.l2_transaction_hash) do
      [] ->
        deposits

      l2_transaction_hashes ->
        inputs =
          from(t in Transaction, where: t.hash in ^l2_transaction_hashes, select: {t.hash, t.input})
          |> select_repo(options).all(timeout: :infinity)
          |> Map.new()

        messenger = MessageRelay.l2_cross_domain_messenger()

        Enum.map(deposits, fn
          %{status: @relay_failed, is_legacy: false} = deposit ->
            %{deposit | msg_data: inputs[deposit.l2_transaction_hash], msg_target_address_hash: messenger}

          deposit ->
            deposit
        end)
    end
  end

  # The page of withdrawals is cut to its size in a subquery, so that only its rows are joined to their blocks and
  # finalizations
  defp withdrawals_query(address_hash, legacy?, options) do
    from(w in subquery(withdrawals_page(address_hash, legacy?, options)),
      left_join: b in Block,
      on: b.number == w.l2_block_number and b.consensus == true,
      left_join: we in WithdrawalEvent,
      on: we.withdrawal_hash == w.hash and we.l1_event_type == :WithdrawalFinalized,
      # a withdrawal is finalized once; a reorged L1 block can leave a second finalization behind, so the latest wins
      distinct: [desc: w.msg_nonce],
      order_by: [desc: w.msg_nonce, desc: we.l1_block_number],
      select: %{
        msg_nonce: w.msg_nonce,
        hash: w.hash,
        l2_transaction_hash: w.l2_transaction_hash,
        l2_block_number: w.l2_block_number,
        l2_timestamp: coalesce(w.legacy_timestamp, b.timestamp),
        l1_transaction_hash: we.l1_transaction_hash,
        message_hash: w.message_hash,
        legacy_message_hash: w.legacy_message_hash,
        transfer_type: w.transfer_type,
        transfer_from_address_hash: w.transfer_from_address_hash,
        transfer_to_address_hash: w.transfer_to_address_hash,
        l1_token_address_hash: w.l1_token_address_hash,
        l2_token_address_hash: w.l2_token_address_hash,
        transfer_amount: w.transfer_amount,
        mnt_value: w.mnt_value,
        eth_value: w.eth_value,
        is_legacy: w.is_legacy,
        migrated_msg_data: w.migrated_msg_data,
        migrated_gas_limit: w.migrated_gas_limit
      }
    )
  end

  defp withdrawals_page(address_hash, legacy?, options) do
    sides =
      for(filter <- side_filters(address_hash, :l2_transaction_hash, options), do: withdrawal_side(filter, options)) ++
        if legacy?,
          do:
            for(
              filter <- side_filters(address_hash, :transaction_hash, options),
              do: legacy_withdrawal_side(filter, options)
            ),
          else: []

    from(w in subquery(union_sides(sides)),
      order_by: [desc: w.msg_nonce],
      limit: ^Keyword.fetch!(options, :limit)
    )
  end

  defp withdrawal_side(filter, options) do
    from(w in Withdrawal,
      order_by: [desc: w.msg_nonce],
      limit: ^Keyword.fetch!(options, :limit),
      # the columns of every withdrawal side, in one order: UNION matches them by position
      select: %{
        msg_nonce: w.msg_nonce,
        hash: w.hash,
        l2_transaction_hash: w.l2_transaction_hash,
        l2_block_number: w.l2_block_number,
        legacy_timestamp: type(^nil, :utc_datetime_usec),
        message_hash: w.message_hash,
        legacy_message_hash: type(^nil, Hash.Full),
        transfer_type: w.transfer_type,
        transfer_from_address_hash: w.transfer_from_address_hash,
        transfer_to_address_hash: w.transfer_to_address_hash,
        l1_token_address_hash: w.l1_token_address_hash,
        l2_token_address_hash: w.l2_token_address_hash,
        transfer_amount: w.transfer_amount,
        mnt_value: w.mnt_value,
        eth_value: w.eth_value,
        is_legacy: false,
        migrated_msg_data: type(^nil, Data),
        migrated_gas_limit: type(^nil, :decimal)
      }
    )
    |> filter_side(filter)
    |> page_by_nonce(:msg_nonce, Keyword.get(options, :paging_key))
  end

  # A v1 withdrawal goes by the identity the migration gave it: the v2 portal proves and finalizes its migrated hash,
  # and the v2 messenger relays its migrated message
  defp legacy_withdrawal_side(filter, options) do
    from(t in LegacyBridgeTransfer,
      # a literal, so that the partial indexes of the direction serve any plan, generic ones included
      where: fragment("? = 'withdrawal'", t.direction),
      order_by: [desc: t.nonce],
      limit: ^Keyword.fetch!(options, :limit),
      select: %{
        msg_nonce: t.nonce,
        hash: t.migrated_withdrawal_hash,
        l2_transaction_hash: t.transaction_hash,
        l2_block_number: t.block_number,
        legacy_timestamp: t.timestamp,
        message_hash: t.migrated_message_hash,
        legacy_message_hash: t.message_hash,
        transfer_type: t.transfer_type,
        transfer_from_address_hash: t.transfer_from_address_hash,
        transfer_to_address_hash: t.transfer_to_address_hash,
        l1_token_address_hash: t.l1_token_address_hash,
        l2_token_address_hash: t.l2_token_address_hash,
        transfer_amount: t.transfer_amount,
        mnt_value: type(^nil, :decimal),
        eth_value: type(^nil, :decimal),
        is_legacy: true,
        migrated_msg_data: t.migrated_msg_data,
        migrated_gas_limit: t.migrated_gas_limit
      }
    )
    |> filter_side(filter)
    |> page_by_nonce(:nonce, Keyword.get(options, :paging_key))
  end

  defp page_by_nonce(query, _column, nil), do: query
  defp page_by_nonce(query, column, nonce), do: where(query, [r], field(r, ^column) < ^nonce)

  # A v1 withdrawal relayed by the legacy L1 messenger, under its v0 hash, was delivered then: that relay was its
  # finalization. Otherwise its relay is the v2 messenger's, under its migrated message hash; a v1-era failure does not
  # count, as the v2 messenger keeps no record of it and the withdrawal is proven and finalized anew.
  defp with_relay(%{is_legacy: true} = row, relays) do
    case Map.get(relays, row.legacy_message_hash) do
      %{status: :relayed, transaction_hash: transaction_hash} = relay ->
        put_relay(%{row | l1_transaction_hash: transaction_hash}, relay)

      _ ->
        put_relay(row, Map.get(relays, row.message_hash))
    end
  end

  defp with_relay(row, relays), do: put_relay(row, Map.get(relays, row.message_hash))

  defp put_relay(row, relay) do
    Map.merge(row, %{
      relay_status: relay[:status],
      relay_transaction_hash: relay[:transaction_hash],
      msg_data: nil,
      msg_target_address_hash: nil,
      msg_gas_limit: nil
    })
  end

  # A replay of a failed L1 relay calls the L1CrossDomainMessenger with the message the MessagePassed event carries.
  # One query, for the relay-failed v2 withdrawals of the page only; a log counts only if it carries the withdrawal's
  # own hash, which keeps out a log that a reorged block left under the same transaction and nonce. A v1 withdrawal is
  # replayed with its migrated message, which its row holds.
  defp with_withdrawal_replay_payloads(withdrawals, options) do
    payloads =
      withdrawals
      |> Enum.flat_map(fn
        %{status: @relay_failed, is_legacy: false} = withdrawal -> [withdrawal.msg_nonce]
        _withdrawal -> []
      end)
      |> withdrawal_replay_payloads(options)

    Enum.map(withdrawals, fn
      %{status: @relay_failed, is_legacy: true} = withdrawal ->
        Map.merge(withdrawal, %{
          msg_data: withdrawal.migrated_msg_data,
          msg_target_address_hash: legacy_relay_target(),
          msg_gas_limit: withdrawal.migrated_gas_limit && Decimal.to_integer(withdrawal.migrated_gas_limit)
        })

      %{status: @relay_failed} = withdrawal ->
        Map.merge(withdrawal, Map.get(payloads, withdrawal.msg_nonce, %{}))

      withdrawal ->
        withdrawal
    end)
  end

  # The L1CrossDomainMessenger that relays migrated withdrawals
  defp legacy_relay_target do
    case BridgeMessage.bridges() do
      nil -> nil
      bridges -> bridges.l1_cross_domain_messenger
    end
  end

  defp withdrawal_replay_payloads([], _options), do: %{}

  defp withdrawal_replay_payloads(nonces, options) do
    event = Withdrawal.message_passed_event()
    message_passer = Withdrawal.message_passer()

    from(w in Withdrawal,
      join: log in Log,
      on:
        log.transaction_hash == w.l2_transaction_hash and log.address_hash == ^message_passer and
          log.first_topic == ^event and log.second_topic == fragment("numeric_to_bytea32(?)", w.msg_nonce),
      where: w.msg_nonce in ^nonces,
      select: {w.msg_nonce, w.hash, log.fourth_topic, log.data}
    )
    |> select_repo(options).all(timeout: :infinity)
    |> Enum.flat_map(fn {nonce, hash, target, data} ->
      message = Withdrawal.parse_message_passed_data(data)

      if message.hash == hash.bytes do
        [
          {nonce,
           %{
             msg_data: %Data{bytes: message.data},
             msg_target_address_hash: BridgeMessage.topic_to_address(target),
             msg_gas_limit: message.gas_limit
           }}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end
end
