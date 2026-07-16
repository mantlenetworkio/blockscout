defmodule Explorer.Chain.ScaledUi.Timeline do
  @moduledoc """
  Replays ERC-8056 multiplier events into a trusted current-state summary.

  Scheduled values are settled against block timestamps, while event anchors
  detect gaps or malformed overwrite sequences before they can affect displayed
  token amounts.
  """

  alias Explorer.Chain.ScaledUi.TokenState
  alias Explorer.Chain.ScaledUiMultiplierUpdate

  defmodule Summary do
    @moduledoc "The rebuildable state derived from a multiplier event timeline."

    @type t :: %__MODULE__{
            base_multiplier: Decimal.t() | nil,
            base_source: {integer(), integer()} | nil,
            pending_multiplier: Decimal.t() | nil,
            pending_effective_at: Decimal.t() | nil,
            pending_source: {integer(), integer()} | nil,
            timeline_status: String.t() | nil,
            tainted_from_block: integer() | nil
          }

    defstruct base_multiplier: nil,
              base_source: nil,
              pending_multiplier: nil,
              pending_effective_at: nil,
              pending_source: nil,
              timeline_status: nil,
              tainted_from_block: nil
  end

  @type event :: ScaledUiMultiplierUpdate.t() | map()

  @doc "Replays events in block and log order into a summary."
  @spec replay([event()]) :: Summary.t()
  def replay(events) when is_list(events) do
    events
    |> Enum.sort_by(&event_position/1)
    |> replay_events(%Summary{})
  end

  @doc "Returns the replayed summary and display status for each event position."
  @spec classify_events([event()], Decimal.t()) :: {Summary.t(), map()}
  def classify_events(events, head_timestamp) when is_list(events) do
    sorted_events = Enum.sort_by(events, &event_position/1)

    summary =
      sorted_events
      |> replay_events(%Summary{})
      |> settle(head_timestamp)

    statuses = Map.new(sorted_events, &{event_position(&1), event_status(&1, summary)})

    {summary, statuses}
  end

  @doc "Returns the trusted multiplier immediately before a block and log position."
  @spec multiplier_at([event()], integer(), integer(), Decimal.t()) :: Decimal.t() | nil
  def multiplier_at(events, block_number, log_index, block_timestamp) when is_list(events) do
    summary =
      events
      |> Enum.filter(&(event_position(&1) < {block_number, log_index}))
      |> replay()
      |> settle(block_timestamp)

    if summary.timeline_status == "ok", do: summary.base_multiplier
  end

  @doc "Returns a state summary's multiplier at the supplied canonical head timestamp."
  @spec current_multiplier(TokenState.t() | map() | nil, Decimal.t()) :: {:ok, Decimal.t()} | :unknown
  def current_multiplier(nil, _head_timestamp), do: :unknown

  def current_multiplier(state, head_timestamp) do
    with "ok" <- Map.get(state, :timeline_status),
         %Decimal{} = base_multiplier <- Map.get(state, :base_multiplier) do
      current_multiplier_from_trusted_state(state, base_multiplier, head_timestamp)
    else
      _ -> :unknown
    end
  end

  defp replay_events([], summary), do: summary
  defp replay_events(_events, %Summary{timeline_status: "tainted"} = summary), do: summary

  defp replay_events([first, second | rest], summary) do
    if overwrite_pair?(first, second) do
      first
      |> event_timestamp()
      |> then(&settle(summary, &1))
      |> apply_overwrite_pair(first, second)
      |> then(&replay_events(rest, &1))
    else
      replay_single_event(first, [second | rest], summary)
    end
  end

  defp replay_events([event], summary), do: replay_single_event(event, [], summary)

  defp replay_single_event(event, rest, summary) do
    summary = settle(summary, event_timestamp(event))

    next_summary =
      case Map.get(event, :event_type) do
        "updated" -> apply_updated(summary, event)
        "overwritten" -> taint(summary, event)
        _ -> taint(summary, event)
      end

    replay_events(rest, next_summary)
  end

  defp apply_updated(%Summary{} = summary, event) do
    cond do
      not valid_base_anchor?(summary, Map.get(event, :old_multiplier)) ->
        taint(summary, event)

      not is_nil(summary.pending_multiplier) ->
        taint(summary, event)

      true ->
        summary
        |> mark_ok()
        |> schedule(
          Map.get(event, :new_multiplier),
          Map.get(event, :effective_at),
          event_timestamp(event),
          event
        )
    end
  end

  defp apply_overwrite_pair(summary, first, second) do
    {updated, overwritten} = order_pair(first, second)

    if valid_base_anchor?(summary, Map.get(updated, :old_multiplier)) and
         valid_pending_anchor?(summary, overwritten) and
         same_schedule?(updated, overwritten) do
      summary
      |> mark_ok()
      |> schedule(
        Map.get(updated, :new_multiplier),
        Map.get(updated, :effective_at),
        event_timestamp(updated),
        second
      )
    else
      taint(summary, first)
    end
  end

  defp overwrite_pair?(first, second) do
    MapSet.new([Map.get(first, :event_type), Map.get(second, :event_type)]) ==
      MapSet.new(["updated", "overwritten"]) and
      Map.get(first, :transaction_hash) == Map.get(second, :transaction_hash) and
      Map.get(first, :block_number) == Map.get(second, :block_number) and
      Map.get(second, :log_index) == Map.get(first, :log_index) + 1
  end

  defp order_pair(%{event_type: "updated"} = updated, overwritten), do: {updated, overwritten}
  defp order_pair(overwritten, updated), do: {updated, overwritten}

  defp valid_base_anchor?(%Summary{base_multiplier: nil}, old_multiplier),
    do: decimal_equal?(old_multiplier, Decimal.new(0))

  defp valid_base_anchor?(%Summary{base_multiplier: base_multiplier}, old_multiplier),
    do: decimal_equal?(base_multiplier, old_multiplier)

  defp valid_pending_anchor?(
         %Summary{pending_multiplier: pending_multiplier, pending_effective_at: pending_effective_at},
         overwritten
       ) do
    not is_nil(pending_multiplier) and
      decimal_equal?(pending_multiplier, Map.get(overwritten, :overwritten_multiplier)) and
      decimal_equal?(pending_effective_at, Map.get(overwritten, :overwritten_effective_at))
  end

  defp same_schedule?(updated, overwritten) do
    decimal_equal?(Map.get(updated, :new_multiplier), Map.get(overwritten, :new_multiplier)) and
      decimal_equal?(Map.get(updated, :effective_at), Map.get(overwritten, :effective_at))
  end

  defp schedule(summary, new_multiplier, effective_at, block_timestamp, source_event) do
    source = event_position(source_event)

    if decimal_lte?(effective_at, block_timestamp) do
      %{
        summary
        | base_multiplier: new_multiplier,
          base_source: source,
          pending_multiplier: nil,
          pending_effective_at: nil,
          pending_source: nil
      }
    else
      %{
        summary
        | pending_multiplier: new_multiplier,
          pending_effective_at: effective_at,
          pending_source: source
      }
    end
  end

  defp settle(%Summary{pending_multiplier: nil} = summary, _at_timestamp), do: summary

  defp settle(%Summary{} = summary, at_timestamp) do
    if decimal_lte?(summary.pending_effective_at, at_timestamp) do
      %{
        summary
        | base_multiplier: summary.pending_multiplier,
          base_source: summary.pending_source,
          pending_multiplier: nil,
          pending_effective_at: nil,
          pending_source: nil
      }
    else
      summary
    end
  end

  defp mark_ok(summary), do: %{summary | timeline_status: "ok", tainted_from_block: nil}

  defp taint(summary, event) do
    %{summary | timeline_status: "tainted", tainted_from_block: Map.get(event, :block_number)}
  end

  defp current_multiplier_from_trusted_state(state, base_multiplier, head_timestamp) do
    case {Map.get(state, :pending_multiplier), Map.get(state, :pending_effective_at)} do
      {nil, nil} ->
        {:ok, base_multiplier}

      {%Decimal{} = pending_multiplier, %Decimal{} = pending_effective_at} ->
        if decimal_lte?(pending_effective_at, head_timestamp),
          do: {:ok, pending_multiplier},
          else: {:ok, base_multiplier}

      _ ->
        :unknown
    end
  end

  defp event_status(_event, %Summary{timeline_status: status}) when status != "ok", do: "superseded"

  defp event_status(event, summary) do
    position = event_position(event)

    cond do
      position == summary.pending_source -> "pending"
      position == summary.base_source -> "active"
      true -> "superseded"
    end
  end

  defp event_position(event), do: {Map.get(event, :block_number), Map.get(event, :log_index)}
  defp event_timestamp(event), do: Map.get(event, :block_timestamp)

  defp decimal_equal?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)
  defp decimal_equal?(_left, _right), do: false

  defp decimal_lte?(%Decimal{} = left, %Decimal{} = right), do: Decimal.compare(left, right) != :gt
  defp decimal_lte?(_left, _right), do: false
end
