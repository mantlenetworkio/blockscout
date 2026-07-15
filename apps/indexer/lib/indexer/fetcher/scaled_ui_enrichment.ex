defmodule Indexer.Fetcher.ScaledUiEnrichment do
  @moduledoc """
  Periodically re-evaluates ERC-8056 transfer snapshots whose multiplier was
  unavailable during their initial import.
  """

  use GenServer
  use Indexer.Fetcher, restart: :permanent

  import Ecto.Query

  alias Explorer.Chain.{Block, Hash, ScaledUiMultiplierUpdate, TokenTransfer}
  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.ScaledUi.{BackfillGap, Status, Timeline, TokenState}
  alias Explorer.Migrator.ScaledUiBackfill
  alias Explorer.Repo

  @batch_size 500
  @gap_lease_seconds 300
  @interval :timer.seconds(10)
  @timeout :timer.minutes(1)

  def child_spec([init_arguments]) do
    child_spec([init_arguments, []])
  end

  def child_spec([_init_arguments, _gen_server_options] = start_link_arguments) do
    default = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments}
    }

    Supervisor.child_spec(default, [])
  end

  def start_link(init_options, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, init_options, gen_server_options)
  end

  @impl GenServer
  def init(_options) do
    send(self(), :enrich)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:enrich, state) do
    enrichment_result = enrich_page(cursor: state)
    retry_backfill_gaps()

    next_state =
      case enrichment_result do
        {:ok, _count, nil} ->
          Process.send_after(self(), :enrich, interval())
          nil

        {:ok, _count, next_cursor} ->
          send(self(), :enrich)
          next_cursor
      end

    {:noreply, next_state}
  end

  @doc false
  def retry_backfill_gaps(options \\ []) do
    lease_seconds = Keyword.get(options, :lease_seconds, @gap_lease_seconds)

    retry_options = %{
      backfill: Keyword.get(options, :backfill, &backfill_claim/2),
      heartbeat_interval: Keyword.get(options, :heartbeat_interval, max(div(lease_seconds, 3), 1)),
      lease_seconds: lease_seconds,
      remaining: Keyword.get(options, :batch_size, 10),
      renew_claim: Keyword.get(options, :renew_claim, &BackfillGap.renew_claim/2)
    }

    retry_due_gaps(retry_options)
    :ok
  end

  @doc "Re-evaluates one batch after the supporting partial index is available."
  @spec enrich_batch(keyword()) :: {:ok, non_neg_integer()}
  def enrich_batch(options \\ []) do
    case enrich_page(options) do
      {:ok, count, _next_cursor} -> {:ok, count}
    end
  end

  @doc false
  def enrich_page(options \\ []) do
    if BackgroundMigrations.get_heavy_indexes_create_token_transfers_ui_amount_status_unknown_index_finished() do
      candidates = candidates(Keyword.get(options, :batch_size, batch_size()), Keyword.get(options, :cursor))

      with {:ok, count} <- enrich_candidates(candidates) do
        {:ok, count, candidate_cursor(List.last(candidates))}
      end
    else
      {:ok, 0, nil}
    end
  end

  @doc false
  def candidates(limit), do: candidates(limit, nil)

  def candidates(limit, cursor) when is_integer(limit) and limit > 0 do
    query =
      from(transfer in TokenTransfer,
        join: block in Block,
        on: block.hash == transfer.block_hash,
        join: state in TokenState,
        on: state.token_contract_address_hash == transfer.token_contract_address_hash,
        where: transfer.ui_amount_status == "unknown",
        where: transfer.block_consensus == true,
        where: block.consensus == true,
        where: not is_nil(transfer.transaction_hash),
        where: not is_nil(state.capability_block),
        where: transfer.block_number >= state.capability_block,
        order_by: [
          asc: transfer.token_contract_address_hash,
          asc: transfer.block_number,
          asc: transfer.block_hash,
          asc: transfer.transaction_hash,
          asc: transfer.log_index
        ],
        limit: ^limit,
        select: %{
          amount: transfer.amount,
          block_hash: transfer.block_hash,
          block_number: transfer.block_number,
          block_timestamp: block.timestamp,
          log_index: transfer.log_index,
          token_contract_address_hash: transfer.token_contract_address_hash,
          transaction_hash: transfer.transaction_hash,
          ui_value: transfer.ui_value
        }
      )

    query
    |> after_cursor(cursor)
    |> Repo.all(timeout: @timeout)
  end

  @doc false
  def enrich_candidates([]), do: {:ok, 0}

  def enrich_candidates(candidates) when is_list(candidates) do
    events_by_token = load_events(candidates)

    updates =
      Enum.flat_map(candidates, fn candidate ->
        events = Map.get(events_by_token, candidate.token_contract_address_hash, [])
        timestamp = Decimal.new(DateTime.to_unix(candidate.block_timestamp))

        case Timeline.multiplier_at(events, candidate.block_number, candidate.log_index, timestamp) do
          %Decimal{} = multiplier ->
            [
              %{
                block_hash: candidate.block_hash,
                log_index: candidate.log_index,
                multiplier: multiplier,
                status: candidate.amount |> Status.judge(candidate.ui_value, multiplier) |> Atom.to_string(),
                transaction_hash: candidate.transaction_hash
              }
            ]

          nil ->
            []
        end
      end)

    update_transfers(updates)
  end

  defp load_events(candidates) do
    token_hashes = candidates |> Enum.map(& &1.token_contract_address_hash) |> Enum.uniq()

    from(update in ScaledUiMultiplierUpdate,
      join: block in Block,
      on: block.hash == update.block_hash,
      where: update.token_contract_address_hash in ^token_hashes,
      where: block.consensus == true,
      order_by: [asc: update.token_contract_address_hash, asc: update.block_number, asc: update.log_index]
    )
    |> Repo.all(timeout: @timeout)
    |> Enum.group_by(& &1.token_contract_address_hash)
  end

  defp update_transfers([]), do: {:ok, 0}

  defp update_transfers(updates) do
    {transaction_hashes, block_hashes, log_indexes, multipliers, statuses} =
      Enum.reduce(updates, {[], [], [], [], []}, fn update,
                                                    {transaction_hashes, block_hashes, log_indexes, multipliers,
                                                     statuses} ->
        {:ok, block_hash} = Hash.Full.dump(update.block_hash)
        {:ok, transaction_hash} = Hash.Full.dump(update.transaction_hash)

        {
          [transaction_hash | transaction_hashes],
          [block_hash | block_hashes],
          [update.log_index | log_indexes],
          [update.multiplier | multipliers],
          [update.status | statuses]
        }
      end)

    now = DateTime.utc_now()

    query =
      from(transfer in TokenTransfer,
        join:
          replacement in fragment(
            "(SELECT unnest(?::bytea[]) AS transaction_hash, unnest(?::bytea[]) AS block_hash, unnest(?::integer[]) AS log_index, unnest(?::numeric[]) AS multiplier, unnest(?::varchar[]) AS status)",
            ^transaction_hashes,
            ^block_hashes,
            ^log_indexes,
            ^multipliers,
            ^statuses
          ),
        on:
          transfer.transaction_hash == replacement.transaction_hash and transfer.block_hash == replacement.block_hash and
            transfer.log_index == replacement.log_index,
        join: block in Block,
        on: block.hash == transfer.block_hash,
        where: transfer.ui_amount_status == "unknown",
        where: transfer.block_consensus == true,
        where: block.consensus == true,
        update: [
          set: [
            ui_multiplier: type(replacement.multiplier, :decimal),
            ui_amount_status: type(replacement.status, :string),
            updated_at: ^now
          ]
        ]
      )

    {count, _} = Repo.update_all(query, [], timeout: @timeout)
    {:ok, count}
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, cursor) do
    where(
      query,
      [transfer, _block, _state],
      fragment(
        "ROW(?, ?, ?, ?, ?) > ROW(?, ?, ?, ?, ?)",
        transfer.token_contract_address_hash,
        transfer.block_number,
        transfer.block_hash,
        transfer.transaction_hash,
        transfer.log_index,
        type(^cursor.token_contract_address_hash, Hash.Address),
        ^cursor.block_number,
        type(^cursor.block_hash, Hash.Full),
        type(^cursor.transaction_hash, Hash.Full),
        ^cursor.log_index
      )
    )
  end

  defp candidate_cursor(nil), do: nil

  defp candidate_cursor(candidate) do
    Map.take(candidate, [
      :token_contract_address_hash,
      :block_number,
      :block_hash,
      :transaction_hash,
      :log_index
    ])
  end

  defp batch_size do
    Application.get_env(:indexer, __MODULE__, [])[:batch_size] || @batch_size
  end

  defp interval do
    Application.get_env(:indexer, __MODULE__, [])[:interval] || @interval
  end

  defp retry_due_gaps(%{remaining: remaining}) when remaining <= 0, do: :ok

  defp retry_due_gaps(options) do
    case BackfillGap.claim_due(lease_seconds: options.lease_seconds) do
      [] ->
        :ok

      [claim] ->
        retry_backfill_gap(claim, options)
        retry_due_gaps(%{options | remaining: options.remaining - 1})
    end
  end

  defp retry_backfill_gap(claim, options) do
    result =
      with_claim_heartbeat(claim, options, fn cancellation_check ->
        retry_claim(claim, cancellation_check, options.backfill)
      end)

    case result do
      {:ok, _backfill_result} -> BackfillGap.complete_claim(claim)
      {:error, reason} -> BackfillGap.fail_claim(claim, reason)
    end
  rescue
    error -> BackfillGap.fail_claim(claim, error)
  end

  defp retry_claim(claim, cancellation_check, backfill) do
    case cancellation_check.() do
      :ok -> retry_active_claim(claim, cancellation_check, backfill)
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_active_claim(claim, cancellation_check, backfill) do
    if ScaledUiBackfill.range_missing?(claim.from_block, claim.to_block) do
      {:error, :block_range_still_missing}
    else
      backfill.(claim, cancellation_check)
    end
  end

  defp backfill_claim(claim, cancellation_check) do
    case ScaledUiBackfill.migration_target_head() do
      {:ok, target_head} ->
        ScaledUiBackfill.backfill_token(claim.token_contract_address_hash, target_head,
          cancellation_check: cancellation_check
        )

      :error ->
        {:error, :backfill_target_head_unavailable}
    end
  end

  defp with_claim_heartbeat(claim, options, callback) do
    owner = self()
    heartbeat_ref = make_ref()

    {heartbeat, monitor_ref} =
      spawn_monitor(fn ->
        claim_heartbeat(owner, heartbeat_ref, claim, options)
      end)

    cancellation_check = fn -> claim_heartbeat_status(heartbeat_ref, monitor_ref) end

    try do
      run_with_cancellation_check(callback, cancellation_check)
    after
      stop_claim_heartbeat(heartbeat, monitor_ref)
    end
  end

  defp run_with_cancellation_check(callback, cancellation_check) do
    case cancellation_check.() do
      :ok -> ensure_claim_after_callback(callback.(cancellation_check), cancellation_check)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_claim_after_callback(result, cancellation_check) do
    case cancellation_check.() do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_heartbeat(owner, heartbeat_ref, claim, options) do
    owner_ref = Process.monitor(owner)
    claim_heartbeat_loop(owner, owner_ref, heartbeat_ref, claim, options)
  end

  defp claim_heartbeat_loop(owner, owner_ref, heartbeat_ref, claim, options) do
    receive do
      {:stop, caller, stop_ref} ->
        send(caller, {:stopped, stop_ref})

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        :ok
    after
      :timer.seconds(options.heartbeat_interval) ->
        case options.renew_claim.(claim, lease_seconds: options.lease_seconds) do
          {count, _} when count > 0 -> claim_heartbeat_loop(owner, owner_ref, heartbeat_ref, claim, options)
          _ -> send(owner, {:scaled_ui_backfill_claim_lost, heartbeat_ref})
        end
    end
  end

  defp claim_heartbeat_status(heartbeat_ref, monitor_ref) do
    receive do
      {:scaled_ui_backfill_claim_lost, ^heartbeat_ref} -> {:error, :backfill_claim_lost}
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> {:error, :backfill_claim_lost}
    after
      0 -> :ok
    end
  end

  defp stop_claim_heartbeat(heartbeat, monitor_ref) do
    if Process.alive?(heartbeat) do
      stop_ref = make_ref()
      send(heartbeat, {:stop, self(), stop_ref})

      receive do
        {:stopped, ^stop_ref} -> :ok
        {:DOWN, ^monitor_ref, :process, ^heartbeat, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end

    Process.demonitor(monitor_ref, [:flush])
  end
end
