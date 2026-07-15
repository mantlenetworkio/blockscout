defmodule Explorer.Migrator.ScaledUiBackfill do
  @moduledoc """
  Backfills ERC-8056 timelines and transfer snapshots from canonical database logs.

  The target head is fixed when the migration starts. Missing block coverage is
  persisted separately and keeps completion pending until the normal catchup
  pipeline has imported the required blocks, transactions, and logs.
  """

  use Explorer.Migrator.FillingMigration

  require Logger

  import Ecto.Query

  alias EthereumJSONRPC.Utility.RangesHelper
  alias Explorer.Chain.{Block, Hash, InternalTransaction, Log, ScaledUiMultiplierUpdate, TokenTransfer, Transaction}
  alias Explorer.Chain.Cache.Counters.AddressTabsElementsCount
  alias Explorer.Chain.Import
  alias Explorer.Chain.Import.Runner.ScaledUiMultiplierUpdates
  alias Explorer.Chain.ScaledUi.{BackfillGap, Events, MultiplierParser, Status, Timeline, TokenState, TransferPairing}
  alias Explorer.Migrator.{FillingMigration, MigrationStatus}
  alias Explorer.Repo
  alias Explorer.Utility.MissingBlockRange

  @default_transfer_batch_size 500
  @migration_name "scaled_ui_backfill"
  @timeout :infinity

  @impl FillingMigration
  def migration_name, do: @migration_name

  @impl FillingMigration
  def last_unprocessed_identifiers(state) do
    {target_head, state} = ensure_target_head(state)
    cursor = Map.get(state, "last_token_hash")
    limit = batch_size() * concurrency()

    token_hashes = discover_token_hashes(target_head, cursor, limit)

    case token_hashes do
      [] ->
        if pending_work?(target_head) do
          {[:wait], state}
        else
          {[], state}
        end

      _ ->
        last_token_hash = token_hashes |> List.last() |> to_string()
        identifiers = Enum.map(token_hashes, &{&1, target_head})
        {identifiers, Map.put(state, "last_token_hash", last_token_hash)}
    end
  end

  @impl FillingMigration
  def unprocessed_data_query, do: nil

  @impl FillingMigration
  def update_batch([:wait]), do: :ok

  def update_batch(identifiers) do
    Enum.each(identifiers, fn {token_hash, target_head} -> backfill_token!(token_hash, target_head) end)
  end

  @impl FillingMigration
  def update_cache, do: :ok

  @impl FillingMigration
  def on_finish do
    Repo.query!("ALTER TABLE token_transfers VALIDATE CONSTRAINT ui_amount_status_known", [], timeout: @timeout)
    :ok
  end

  @doc "Backfills one token through a fixed canonical head and invalidates counters after commit."
  def backfill_token(token_hash, target_head) do
    with {:ok, prepared} <- Repo.transaction(fn -> prepare_token(token_hash, target_head) end, timeout: @timeout) do
      updated_transfers =
        case prepared do
          nil -> 0
          prepared -> process_transfer_batches(prepared, nil, 0)
        end

      {:ok, %{token_contract_address_hash: token_hash, updated_transfers: updated_transfers}}
    end
  end

  @doc "Returns whether a claimed range still lacks complete block coverage."
  def range_missing?(from_block, to_block) do
    coverage_gaps(from_block, to_block) != []
  end

  @doc "Returns the fixed canonical head persisted for this migration."
  def migration_target_head do
    case MigrationStatus.fetch(@migration_name) do
      %{meta: %{"target_head" => target_head}} when is_integer(target_head) -> {:ok, target_head}
      _ -> :error
    end
  end

  @doc "Returns the current canonical head."
  def canonical_head do
    Repo.one(from(block in Block, where: block.consensus == true, select: max(block.number)), timeout: @timeout) || -1
  end

  defp backfill_token!(token_hash, target_head) do
    case backfill_token(token_hash, target_head) do
      {:ok, _result} -> :ok
      {:error, reason} -> raise "scaled UI backfill failed: #{inspect(reason)}"
    end
  end

  defp ensure_target_head(%{"target_head" => target_head} = state) when is_integer(target_head),
    do: {target_head, state}

  defp ensure_target_head(state) do
    target_head =
      case migration_target_head() do
        {:ok, persisted_target_head} -> persisted_target_head
        :error -> canonical_head()
      end

    case MigrationStatus.update_meta(@migration_name, %{"target_head" => target_head}) do
      :ok -> :ok
      {:ok, _migration_status} -> :ok
      {:error, changeset} -> raise "failed to persist scaled UI backfill target head: #{inspect(changeset.errors)}"
    end

    {target_head, Map.put(state, "target_head", target_head)}
  end

  defp prepare_token(token_hash, target_head) do
    case capability_block(token_hash, target_head) do
      nil ->
        nil

      capability_block ->
        scan_start = creation_block(token_hash) || capability_block
        gaps = coverage_gaps(scan_start, target_head)

        BackfillGap.put_ranges(Repo, token_hash, gaps)
        import_multiplier_updates(canonical_multiplier_log_rows(token_hash, target_head))

        {:ok, [_]} =
          TokenState.rebuild(Repo, [
            %{token_contract_address_hash: token_hash, capability_block: capability_block}
          ])

        %{
          token_contract_address_hash: token_hash,
          capability_block: capability_block,
          target_head: target_head,
          coverage_missing?: gaps != [],
          multiplier_updates: canonical_multiplier_updates(token_hash)
        }
    end
  end

  defp discover_token_hashes(target_head, cursor, limit) do
    query =
      from(log in Log,
        join: block in Block,
        on: block.hash == log.block_hash,
        where: block.consensus == true,
        where: log.block_number <= ^target_head,
        where: log.first_topic in ^topic_hashes(),
        distinct: log.address_hash,
        order_by: [asc: log.address_hash],
        select: log.address_hash,
        limit: ^limit
      )

    query =
      case cursor do
        nil -> query
        cursor -> where(query, [log, _block], log.address_hash > ^cast_address_hash!(cursor))
      end

    Repo.all(query, timeout: @timeout)
  end

  defp capability_block(token_hash, target_head) do
    Repo.one(
      from(log in Log,
        join: block in Block,
        on: block.hash == log.block_hash,
        where: block.consensus == true,
        where: log.address_hash == ^token_hash,
        where: log.block_number <= ^target_head,
        where: log.first_topic in ^topic_hashes(),
        select: min(log.block_number)
      ),
      timeout: @timeout
    )
  end

  defp canonical_multiplier_log_rows(token_hash, target_head) do
    from(log in Log,
      join: block in Block,
      on: block.hash == log.block_hash,
      where: block.consensus == true,
      where: log.address_hash == ^token_hash,
      where: log.block_number <= ^target_head,
      where: log.first_topic in ^multiplier_topic_hashes(),
      order_by: [asc: log.block_number, asc: log.index],
      select: %{log: log, block_timestamp: block.timestamp}
    )
    |> Repo.all(timeout: @timeout)
  end

  defp import_multiplier_updates(log_rows) do
    changes =
      Enum.flat_map(log_rows, fn %{log: log, block_timestamp: timestamp} ->
        case MultiplierParser.parse_event(log, timestamp) do
          {:ok, update} ->
            [update]

          {:error, :unsupported_topic} ->
            []

          {:error, reason} ->
            Logger.warning(
              "Skipping malformed historical ERC-8056 multiplier event at block #{log.block_number}, " <>
                "log #{log.index}: #{inspect(reason)}"
            )

            []
        end
      end)

    {:ok, _updates} =
      ScaledUiMultiplierUpdates.insert(Repo, changes, %{
        timeout: @timeout,
        timestamps: Import.timestamps()
      })
  end

  defp process_transfer_batches(prepared, cursor, updated_total) do
    transaction_keys = transfer_transaction_keys(prepared, cursor, transfer_batch_size())

    case transaction_keys do
      [] ->
        updated_total

      _ ->
        {:ok, %{addresses: addresses, updated_count: updated_count}} =
          Repo.transaction(
            fn -> backfill_transfer_batch(prepared, transaction_keys) end,
            timeout: @timeout
          )

        invalidate_counters(addresses)

        process_transfer_batches(
          prepared,
          List.last(transaction_keys),
          updated_total + updated_count
        )
    end
  end

  defp transfer_transaction_keys(prepared, cursor, limit) do
    query =
      from(transfer in TokenTransfer,
        join: block in Block,
        on: block.hash == transfer.block_hash,
        where: transfer.token_contract_address_hash == ^prepared.token_contract_address_hash,
        where: transfer.token_type == "ERC-20",
        where: transfer.block_number >= ^prepared.capability_block,
        where: transfer.block_number <= ^prepared.target_head,
        where: transfer.block_consensus == true and block.consensus == true,
        where: not is_nil(transfer.transaction_hash),
        distinct: [transfer.block_number, transfer.block_hash, transfer.transaction_hash],
        order_by: [asc: transfer.block_number, asc: transfer.block_hash, asc: transfer.transaction_hash],
        select: %{
          block_number: transfer.block_number,
          block_hash: transfer.block_hash,
          transaction_hash: transfer.transaction_hash
        },
        limit: ^limit
      )

    query =
      case cursor do
        nil ->
          query

        cursor ->
          where(
            query,
            [transfer, _block],
            transfer.block_number > ^cursor.block_number or
              (transfer.block_number == ^cursor.block_number and transfer.block_hash > ^cursor.block_hash) or
              (transfer.block_number == ^cursor.block_number and transfer.block_hash == ^cursor.block_hash and
                 transfer.transaction_hash > ^cursor.transaction_hash)
          )
      end

    Repo.all(query, timeout: @timeout)
  end

  defp backfill_transfer_batch(prepared, transaction_keys) do
    transfer_rows = canonical_transfer_rows(prepared.token_contract_address_hash, transaction_keys)
    transfers = Enum.map(transfer_rows, & &1.transfer)
    ui_events = load_ui_events(prepared.token_contract_address_hash, transaction_keys)
    {matches, _orphan_count} = TransferPairing.pair(transfers, ui_events)

    updates =
      Enum.map(
        transfer_rows,
        &transfer_update(&1, matches, prepared.multiplier_updates, prepared.coverage_missing?)
      )

    update_keys = MapSet.new(updates, & &1.key)

    addresses =
      transfer_rows
      |> Enum.filter(&(is_nil(&1.transfer.ui_amount_status) and update_key(&1.transfer) in update_keys))
      |> Enum.flat_map(&[&1.transfer.from_address_hash, &1.transfer.to_address_hash])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {updated_count, _} = update_transfers(updates)
    %{addresses: addresses, updated_count: updated_count}
  end

  defp canonical_transfer_rows(token_hash, transaction_keys) do
    {block_hashes, transaction_hashes} = dump_transaction_keys(transaction_keys)

    from(transfer in TokenTransfer,
      join:
        transaction_key in fragment(
          "(SELECT unnest(?::bytea[]) AS block_hash, unnest(?::bytea[]) AS transaction_hash)",
          ^block_hashes,
          ^transaction_hashes
        ),
      on:
        transfer.block_hash == transaction_key.block_hash and
          transfer.transaction_hash == transaction_key.transaction_hash,
      join: block in Block,
      on: block.hash == transfer.block_hash,
      where: transfer.token_contract_address_hash == ^token_hash,
      where: transfer.token_type == "ERC-20",
      where: transfer.block_consensus == true and block.consensus == true,
      order_by: [asc: transfer.block_number, asc: transfer.log_index],
      select: %{transfer: transfer, block_timestamp: block.timestamp}
    )
    |> Repo.all(timeout: @timeout)
  end

  defp load_ui_events(token_hash, transaction_keys) do
    {block_hashes, transaction_hashes} = dump_transaction_keys(transaction_keys)
    ui_topic = hd(ui_topic_hashes())

    from(log in Log,
      join:
        transaction_key in fragment(
          "(SELECT unnest(?::bytea[]) AS block_hash, unnest(?::bytea[]) AS transaction_hash)",
          ^block_hashes,
          ^transaction_hashes
        ),
      on: log.block_hash == transaction_key.block_hash and log.transaction_hash == transaction_key.transaction_hash,
      join: block in Block,
      on: block.hash == log.block_hash,
      where: block.consensus == true,
      where: log.address_hash == ^token_hash,
      where: log.first_topic == ^ui_topic,
      order_by: [asc: log.block_number, asc: log.index]
    )
    |> Repo.all(timeout: @timeout)
    |> Enum.flat_map(fn log ->
      case TransferPairing.parse_event(log) do
        {:ok, event} ->
          [event]

        {:error, reason} ->
          Logger.warning(
            "Skipping malformed historical TransferWithUIAmount event at block #{log.block_number}, " <>
              "log #{log.index}: #{inspect(reason)}"
          )

          []
      end
    end)
  end

  defp canonical_multiplier_updates(token_hash) do
    from(event in ScaledUiMultiplierUpdate,
      join: block in Block,
      on: block.hash == event.block_hash,
      where: event.token_contract_address_hash == ^token_hash,
      where: block.consensus == true,
      order_by: [asc: event.block_number, asc: event.log_index]
    )
    |> Repo.all(timeout: @timeout)
  end

  defp dump_transaction_keys(transaction_keys) do
    transaction_keys
    |> Enum.map(fn key ->
      {:ok, block_hash} = Hash.Full.dump(key.block_hash)
      {:ok, transaction_hash} = Hash.Full.dump(key.transaction_hash)
      {block_hash, transaction_hash}
    end)
    |> Enum.unzip()
  end

  defp transfer_update(%{transfer: transfer, block_timestamp: timestamp}, matches, events, coverage_missing?) do
    key = update_key(transfer)
    ui_value = Map.get(matches, TransferPairing.transfer_key(transfer))

    multiplier =
      if coverage_missing? do
        nil
      else
        Timeline.multiplier_at(
          events,
          transfer.block_number,
          transfer.log_index,
          timestamp |> DateTime.to_unix() |> Decimal.new()
        )
      end

    status =
      if coverage_missing?,
        do: "unknown",
        else: transfer.amount |> Status.judge(ui_value, multiplier) |> Atom.to_string()

    %{
      key: key,
      block_hash: transfer.block_hash,
      log_index: transfer.log_index,
      ui_value: ui_value,
      multiplier: multiplier,
      status: status
    }
  end

  defp update_transfers([]), do: {0, nil}

  defp update_transfers(updates) do
    {block_hashes, log_indexes, ui_values, multipliers, statuses} =
      Enum.reduce(updates, {[], [], [], [], []}, fn update,
                                                    {block_hashes, log_indexes, ui_values, multipliers, statuses} ->
        {:ok, block_hash} = Hash.Full.dump(update.block_hash)

        {
          [block_hash | block_hashes],
          [update.log_index | log_indexes],
          [update.ui_value | ui_values],
          [update.multiplier | multipliers],
          [update.status | statuses]
        }
      end)

    now = DateTime.utc_now()

    from(transfer in TokenTransfer,
      join:
        replacement in fragment(
          "(SELECT unnest(?::bytea[]) AS block_hash, unnest(?::integer[]) AS log_index, unnest(?::numeric[]) AS ui_value, unnest(?::numeric[]) AS multiplier, unnest(?::varchar[]) AS status)",
          ^block_hashes,
          ^log_indexes,
          ^ui_values,
          ^multipliers,
          ^statuses
        ),
      on: transfer.block_hash == replacement.block_hash and transfer.log_index == replacement.log_index,
      join: block in Block,
      on: block.hash == transfer.block_hash,
      where: transfer.block_consensus == true and block.consensus == true,
      where:
        fragment(
          "(?, ?, ?) IS DISTINCT FROM (?, ?, ?)",
          transfer.ui_value,
          transfer.ui_multiplier,
          transfer.ui_amount_status,
          replacement.ui_value,
          replacement.multiplier,
          replacement.status
        ),
      update: [
        set: [
          ui_value: type(replacement.ui_value, :decimal),
          ui_multiplier: type(replacement.multiplier, :decimal),
          ui_amount_status: type(replacement.status, :string),
          updated_at: ^now
        ]
      ]
    )
    |> Repo.update_all([], timeout: @timeout)
  end

  defp coverage_gaps(from_block, to_block) when from_block > to_block, do: []

  defp coverage_gaps(from_block, to_block) do
    (configured_range_gaps(from_block, to_block) ++ MissingBlockRange.intersections(from_block, to_block))
    |> Enum.filter(&(&1.from_block <= &1.to_block))
    |> merge_ranges()
  end

  defp configured_range_gaps(from_block, to_block) do
    first_block = Application.get_env(:indexer, :first_block, 0)
    block_ranges = Application.get_env(:indexer, :block_ranges, "#{first_block}..latest")

    coverage =
      block_ranges
      |> RangesHelper.parse_block_ranges()
      |> Enum.flat_map(fn
        %Range{first: first, last: last} ->
          clipped_range(max(first, from_block), min(last, to_block))

        first when is_integer(first) ->
          clipped_range(max(first, from_block), to_block)
      end)
      |> Enum.sort_by(& &1.from_block)

    {cursor, gaps} =
      Enum.reduce(coverage, {from_block, []}, fn range, {cursor, gaps} ->
        gaps =
          if cursor < range.from_block, do: [%{from_block: cursor, to_block: range.from_block - 1} | gaps], else: gaps

        {max(cursor, range.to_block + 1), gaps}
      end)

    gaps = if cursor <= to_block, do: [%{from_block: cursor, to_block: to_block} | gaps], else: gaps
    Enum.reverse(gaps)
  end

  defp clipped_range(from_block, to_block) when from_block <= to_block,
    do: [%{from_block: from_block, to_block: to_block}]

  defp clipped_range(_from_block, _to_block), do: []

  defp merge_ranges(ranges) do
    ranges
    |> Enum.sort_by(&{&1.from_block, &1.to_block})
    |> Enum.reduce([], fn range, acc ->
      case acc do
        [%{to_block: previous_to} = previous | rest] when range.from_block <= previous_to + 1 ->
          [%{previous | to_block: max(previous_to, range.to_block)} | rest]

        _ ->
          [range | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp creation_block(token_hash) do
    transaction_block =
      Repo.one(
        from(transaction in Transaction,
          where: transaction.created_contract_address_hash == ^token_hash,
          where: transaction.block_consensus == true,
          select: min(transaction.block_number)
        ),
        timeout: @timeout
      )

    internal_transaction_block =
      InternalTransaction
      |> InternalTransaction.where_address_match(:created_contract_address, token_hash)
      |> InternalTransaction.join_transaction_query()
      |> select([internal_transaction, transaction: _transaction], min(internal_transaction.block_number))
      |> Repo.one(timeout: @timeout)

    [transaction_block, internal_transaction_block]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp pending_work?(target_head) do
    BackfillGap.count() > 0 or incomplete_transfers?(target_head)
  end

  defp incomplete_transfers?(target_head) do
    from(transfer in TokenTransfer,
      join: state in TokenState,
      on: state.token_contract_address_hash == transfer.token_contract_address_hash,
      where: not is_nil(state.capability_block),
      where: transfer.block_number >= state.capability_block,
      where: transfer.block_number <= ^target_head,
      where: transfer.block_consensus == true,
      where: is_nil(transfer.ui_amount_status)
    )
    |> Repo.exists?(timeout: @timeout)
  end

  defp invalidate_counters(addresses) do
    addresses
    |> Enum.uniq()
    |> Enum.each(&AddressTabsElementsCount.invalidate_counter(:token_transfers_erc8056, &1))
  end

  defp transfer_batch_size do
    Application.get_env(:explorer, __MODULE__, [])[:transfer_batch_size] || @default_transfer_batch_size
  end

  defp update_key(transfer), do: {transfer.block_hash, transfer.log_index}

  defp topic_hashes do
    multiplier_topic_hashes() ++ ui_topic_hashes()
  end

  defp multiplier_topic_hashes do
    [Events.ui_multiplier_updated_topic(), Events.ui_multiplier_change_overwritten_topic()]
    |> Enum.map(&cast_topic!/1)
  end

  defp ui_topic_hashes, do: [cast_topic!(Events.transfer_with_ui_amount_topic())]

  defp cast_topic!(topic) do
    {:ok, hash} = Hash.Full.cast(topic)
    hash
  end

  defp cast_address_hash!(hash) do
    {:ok, hash} = Hash.Address.cast(hash)
    hash
  end
end
