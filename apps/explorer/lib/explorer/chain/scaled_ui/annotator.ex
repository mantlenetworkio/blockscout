defmodule Explorer.Chain.ScaledUi.Annotator do
  @moduledoc """
  Adds ERC-8056 multiplier snapshots and amount-integrity statuses before import.

  Persisted and in-batch capability evidence and timeline events are combined so
  the first observed batch is handled without waiting for its summary rows.
  """

  import Ecto.Query, only: [from: 2]

  alias Explorer.Chain.ScaledUi.{Status, Timeline, TokenState}
  alias Explorer.Chain.ScaledUiMultiplierUpdate
  alias Explorer.Repo

  @type batch_events :: %{
          required(:updates) => [map()],
          required(:capability_rows) => [map()],
          required(:block_timestamps) => %{integer() => DateTime.t() | Decimal.t()}
        }

  @doc "Annotates transfers from a block-import batch with ERC-8056 snapshot fields."
  @spec annotate([map()], batch_events()) :: [map()]
  def annotate([], _batch_events), do: []

  def annotate(transfers, batch_events) do
    token_hashes =
      transfers
      |> Enum.filter(&scaled_ui_candidate?/1)
      |> Enum.map(& &1.token_contract_address_hash)
      |> Enum.uniq()

    states_by_token = load_states(token_hashes)
    batch_boundaries = batch_capability_boundaries(Map.get(batch_events, :capability_rows, []))
    boundaries = merge_boundaries(states_by_token, batch_boundaries)

    candidate_token_keys = MapSet.new(token_hashes, &hash_key/1)

    timeline_token_hashes =
      boundaries
      |> Map.keys()
      |> Enum.filter(&MapSet.member?(candidate_token_keys, &1))

    events_by_token =
      timeline_token_hashes
      |> load_events()
      |> merge_batch_events(Map.get(batch_events, :updates, []))

    block_timestamps = Map.get(batch_events, :block_timestamps, %{})

    Enum.map(transfers, &annotate_transfer(&1, boundaries, events_by_token, block_timestamps))
  end

  defp load_states([]), do: %{}

  defp load_states(token_hashes) do
    from(state in TokenState,
      where: state.token_contract_address_hash in ^token_hashes
    )
    |> Repo.all()
    |> Map.new(&{hash_key(&1.token_contract_address_hash), &1})
  end

  defp load_events([]), do: %{}

  defp load_events(token_hashes) do
    from(event in ScaledUiMultiplierUpdate,
      where: event.token_contract_address_hash in ^token_hashes,
      order_by: [asc: event.block_number, asc: event.log_index]
    )
    |> Repo.all()
    |> Enum.group_by(&hash_key(&1.token_contract_address_hash))
  end

  defp batch_capability_boundaries(rows) do
    Enum.reduce(rows, %{}, fn row, boundaries ->
      token_hash = hash_key(Map.fetch!(row, :token_contract_address_hash))
      capability_block = Map.fetch!(row, :capability_block)
      Map.update(boundaries, token_hash, capability_block, &min(&1, capability_block))
    end)
  end

  defp merge_boundaries(states_by_token, batch_boundaries) do
    Enum.reduce(states_by_token, batch_boundaries, fn {token_hash, state}, boundaries ->
      case state.capability_block do
        nil -> boundaries
        capability_block -> Map.update(boundaries, token_hash, capability_block, &min(&1, capability_block))
      end
    end)
  end

  defp merge_batch_events(events_by_token, batch_events) do
    batch_events
    |> Enum.group_by(&hash_key(&1.token_contract_address_hash))
    |> Map.merge(events_by_token, fn _token_hash, batch, persisted -> persisted ++ batch end)
    |> Map.new(fn {token_hash, events} -> {token_hash, deduplicate_events(events)} end)
  end

  defp deduplicate_events(events) do
    events
    |> Enum.reduce(%{}, fn event, unique ->
      key = {to_string(Map.get(event, :block_hash)), Map.get(event, :log_index)}
      Map.put(unique, key, event)
    end)
    |> Map.values()
  end

  defp annotate_transfer(transfer, boundaries, events_by_token, block_timestamps) do
    token_hash = hash_key(transfer.token_contract_address_hash)

    case Map.get(boundaries, token_hash) do
      nil ->
        transfer

      capability_block when transfer.block_number < capability_block ->
        Map.merge(transfer, %{ui_value: nil, ui_multiplier: nil, ui_amount_status: nil})

      _capability_block ->
        multiplier =
          multiplier_at(
            Map.get(events_by_token, token_hash, []),
            transfer,
            Map.get(block_timestamps, transfer.block_number)
          )

        status = Status.judge(transfer.amount, Map.get(transfer, :ui_value), multiplier)

        Map.merge(transfer, %{ui_multiplier: multiplier, ui_amount_status: Atom.to_string(status)})
    end
  end

  defp multiplier_at(_events, _transfer, nil), do: nil

  defp multiplier_at(events, transfer, block_timestamp) do
    Timeline.multiplier_at(
      events,
      transfer.block_number,
      transfer.log_index,
      decimal_timestamp(block_timestamp)
    )
  end

  defp decimal_timestamp(%Decimal{} = timestamp), do: timestamp
  defp decimal_timestamp(%DateTime{} = timestamp), do: timestamp |> DateTime.to_unix() |> Decimal.new()

  defp scaled_ui_candidate?(transfer) do
    transfer.token_type == "ERC-20" and match?(%Decimal{}, Map.get(transfer, :amount))
  end

  defp hash_key(hash), do: hash |> to_string() |> String.downcase()
end
