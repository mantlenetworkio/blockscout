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
    enrichment_result = enrich_batch()
    retry_backfill_gaps()

    case enrichment_result do
      {:ok, count} when count > 0 ->
        send(self(), :enrich)

      {:ok, _count} ->
        Process.send_after(self(), :enrich, interval())
    end

    {:noreply, state}
  end

  @doc false
  def retry_backfill_gaps(options \\ []) do
    options
    |> Keyword.get(:batch_size, 10)
    |> BackfillGap.claim_due()
    |> Enum.each(&retry_backfill_gap/1)

    :ok
  end

  @doc "Re-evaluates one batch after the supporting partial index is available."
  @spec enrich_batch(keyword()) :: {:ok, non_neg_integer()}
  def enrich_batch(options \\ []) do
    if BackgroundMigrations.get_heavy_indexes_create_token_transfers_ui_amount_status_unknown_index_finished() do
      options
      |> Keyword.get(:batch_size, batch_size())
      |> candidates()
      |> enrich_candidates()
    else
      {:ok, 0}
    end
  end

  @doc false
  def candidates(limit) when is_integer(limit) and limit > 0 do
    from(transfer in TokenTransfer,
      join: block in Block,
      on: block.hash == transfer.block_hash,
      join: state in TokenState,
      on: state.token_contract_address_hash == transfer.token_contract_address_hash,
      where: transfer.ui_amount_status == "unknown",
      where: transfer.block_consensus == true,
      where: block.consensus == true,
      where: not is_nil(state.capability_block),
      where: transfer.block_number >= state.capability_block,
      order_by: [
        asc: transfer.token_contract_address_hash,
        asc: transfer.block_number,
        asc: transfer.block_hash,
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
        ui_value: transfer.ui_value
      }
    )
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
                status: candidate.amount |> Status.judge(candidate.ui_value, multiplier) |> Atom.to_string()
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
    {block_hashes, log_indexes, multipliers, statuses} =
      Enum.reduce(updates, {[], [], [], []}, fn update, {block_hashes, log_indexes, multipliers, statuses} ->
        {:ok, block_hash} = Hash.Full.dump(update.block_hash)

        {
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
            "(SELECT unnest(?::bytea[]) AS block_hash, unnest(?::integer[]) AS log_index, unnest(?::numeric[]) AS multiplier, unnest(?::varchar[]) AS status)",
            ^block_hashes,
            ^log_indexes,
            ^multipliers,
            ^statuses
          ),
        on: transfer.block_hash == replacement.block_hash and transfer.log_index == replacement.log_index,
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

  defp batch_size do
    Application.get_env(:indexer, __MODULE__, [])[:batch_size] || @batch_size
  end

  defp interval do
    Application.get_env(:indexer, __MODULE__, [])[:interval] || @interval
  end

  defp retry_backfill_gap(claim) do
    result =
      if ScaledUiBackfill.range_missing?(claim.from_block, claim.to_block) do
        {:error, :block_range_still_missing}
      else
        ScaledUiBackfill.backfill_token(
          claim.token_contract_address_hash,
          ScaledUiBackfill.canonical_head()
        )
      end

    case result do
      {:ok, _backfill_result} -> BackfillGap.complete_claim(claim)
      {:error, reason} -> BackfillGap.fail_claim(claim, reason)
    end
  rescue
    error -> BackfillGap.fail_claim(claim, error)
  end
end
