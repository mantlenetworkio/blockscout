defmodule Explorer.Prometheus.ScaledUi do
  @moduledoc "Prometheus metrics for ERC-8056 indexing and data quality."

  use Prometheus.Metric

  @counter [
    name: :scaled_ui_orphan_ui_events_total,
    help: "Number of TransferWithUIAmount events that could not be paired with a token transfer"
  ]

  @counter [
    name: :scaled_ui_event_missing_determinations_total,
    help: "Number of ERC-8056 token transfers determined to be missing a TransferWithUIAmount event"
  ]

  @counter [
    name: :scaled_ui_integrity_failures_total,
    labels: [:source],
    help: "Number of ERC-8056 integrity failures by detection source"
  ]

  @gauge [
    name: :scaled_ui_token_transfers,
    labels: [:status],
    help: "Current number of canonical ERC-8056 token transfers requiring attention by status"
  ]

  @gauge [
    name: :scaled_ui_tainted_tokens,
    help: "Current number of ERC-8056 tokens with a tainted multiplier timeline"
  ]

  @handler_id "explorer-scaled-ui-prometheus"
  @events [
    [:indexer, :scaled_ui, :orphan_ui_event],
    [:explorer, :scaled_ui, :event_missing],
    [:explorer, :scaled_ui, :integrity_failure]
  ]
  @inventory_statuses ~w(unknown mismatch event_missing)

  @spec setup() :: :ok
  def setup do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event([:indexer, :scaled_ui, :orphan_ui_event], %{count: count}, _metadata, _config)
      when is_integer(count) and count > 0 do
    Counter.inc([name: :scaled_ui_orphan_ui_events_total], count)
  end

  def handle_event([:explorer, :scaled_ui, :event_missing], %{count: count}, _metadata, _config)
      when is_integer(count) and count > 0 do
    Counter.inc([name: :scaled_ui_event_missing_determinations_total], count)
  end

  def handle_event(
        [:explorer, :scaled_ui, :integrity_failure],
        %{count: count},
        %{source: source},
        _config
      )
      when is_integer(count) and count > 0 and source in [:coverage_gap, :anchor_break] do
    Counter.inc([name: :scaled_ui_integrity_failures_total, labels: [Atom.to_string(source)]], count)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec set_inventory(%{token_transfers: %{String.t() => non_neg_integer()}, tainted_tokens: non_neg_integer()}) :: :ok
  def set_inventory(%{token_transfers: token_transfers, tainted_tokens: tainted_tokens}) do
    Enum.each(@inventory_statuses, fn status ->
      Gauge.set([name: :scaled_ui_token_transfers, labels: [status]], Map.get(token_transfers, status, 0))
    end)

    Gauge.set([name: :scaled_ui_tainted_tokens], tainted_tokens)
  end
end
