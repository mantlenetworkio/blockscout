defmodule Explorer.Chain.ScaledUi.TransferPairing do
  @moduledoc """
  Deterministically pairs ERC-20 transfers with ERC-8056 UI amount events.

  Adjacent content matches are preferred. Remaining transfers use the first
  matching event in log order, and every UI event can be consumed only once.
  """

  import Explorer.Helper, only: [decode_data: 2, truncate_address_hash: 1]

  @type match_key :: {term(), term(), integer()}

  @doc "Parses one TransferWithUIAmount log into the fields used for pairing."
  @spec parse_event(map()) :: {:ok, map()} | {:error, term()}
  def parse_event(log) do
    [amount, ui_value] = decode_data(to_string(log.data), [{:uint, 256}, {:uint, 256}])

    {:ok,
     %{
       amount: Decimal.new(amount),
       block_hash: log.block_hash,
       from_address_hash: log.second_topic |> to_string() |> truncate_address_hash(),
       log_index: log.index,
       to_address_hash: log.third_topic |> to_string() |> truncate_address_hash(),
       token_contract_address_hash: log.address_hash,
       transaction_hash: log.transaction_hash,
       ui_value: Decimal.new(ui_value)
     }}
  rescue
    error in [FunctionClauseError, MatchError] -> {:error, error}
  end

  @doc "Returns transfer-keyed UI values and the number of unconsumed events."
  @spec pair([map()], [map()]) :: {%{match_key() => Decimal.t()}, non_neg_integer()}
  def pair(transfers, ui_events) do
    transfers_by_group = Enum.group_by(transfers, &group_key/1)
    ui_events_by_group = Enum.group_by(ui_events, &group_key/1)

    matches =
      Enum.reduce(transfers_by_group, %{}, fn {key, grouped_transfers}, matches ->
        Map.merge(matches, match_group(grouped_transfers, Map.get(ui_events_by_group, key, [])))
      end)

    {matches, length(ui_events) - map_size(matches)}
  end

  @doc "Builds the stable database identity used by pairing and backfill updates."
  @spec transfer_key(map()) :: match_key()
  def transfer_key(transfer) do
    {hash_key(transfer.block_hash), hash_key(transfer.transaction_hash), transfer.log_index}
  end

  defp match_group(transfers, ui_events) do
    transfers = Enum.sort_by(transfers, & &1.log_index)
    ui_events = Enum.sort_by(ui_events, & &1.log_index)

    {adjacent_matches, unmatched_transfers, remaining_ui_events} =
      match_events(transfers, ui_events, %{}, &adjacent?/2)

    {matches, _unmatched_transfers, _remaining_ui_events} =
      match_events(unmatched_transfers, remaining_ui_events, adjacent_matches, &content_matches?/2)

    matches
  end

  defp match_events(transfers, ui_events, matches, matcher) do
    Enum.reduce(transfers, {matches, [], ui_events}, fn transfer, {matches, unmatched, ui_events} ->
      case take_first_match(ui_events, &matcher.(transfer, &1)) do
        {nil, ui_events} ->
          {matches, [transfer | unmatched], ui_events}

        {ui_event, ui_events} ->
          {Map.put(matches, transfer_key(transfer), ui_event.ui_value), unmatched, ui_events}
      end
    end)
    |> then(fn {matches, unmatched, ui_events} -> {matches, Enum.reverse(unmatched), ui_events} end)
  end

  defp take_first_match(events, matcher) do
    case Enum.split_while(events, &(not matcher.(&1))) do
      {before, [event | after_events]} -> {event, before ++ after_events}
      {_before, []} -> {nil, events}
    end
  end

  defp adjacent?(transfer, ui_event) do
    abs(transfer.log_index - ui_event.log_index) == 1 and content_matches?(transfer, ui_event)
  end

  defp content_matches?(transfer, ui_event) do
    hash_key(transfer.from_address_hash) == hash_key(ui_event.from_address_hash) and
      hash_key(transfer.to_address_hash) == hash_key(ui_event.to_address_hash) and
      Decimal.equal?(transfer.amount, ui_event.amount)
  end

  defp group_key(event) do
    {
      hash_key(event.block_hash),
      hash_key(event.transaction_hash),
      hash_key(event.token_contract_address_hash)
    }
  end

  defp hash_key(hash), do: hash |> to_string() |> String.downcase()
end
