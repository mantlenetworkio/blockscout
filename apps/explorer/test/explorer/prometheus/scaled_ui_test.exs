defmodule Explorer.Prometheus.ScaledUiTest do
  use ExUnit.Case, async: false

  alias Explorer.Prometheus.ScaledUi
  alias Prometheus.Metric.{Counter, Gauge}

  setup do
    assert :ok = ScaledUi.setup()
    :ok
  end

  test "bridges scaled UI telemetry events to cumulative counters" do
    orphan_before = counter_value(:scaled_ui_orphan_ui_events_total)
    missing_before = counter_value(:scaled_ui_event_missing_determinations_total)
    coverage_before = counter_value(:scaled_ui_integrity_failures_total, ["coverage_gap"])
    anchor_before = counter_value(:scaled_ui_integrity_failures_total, ["anchor_break"])

    :telemetry.execute([:indexer, :scaled_ui, :orphan_ui_event], %{count: 2}, %{})
    :telemetry.execute([:explorer, :scaled_ui, :event_missing], %{count: 3}, %{})
    :telemetry.execute([:explorer, :scaled_ui, :integrity_failure], %{count: 4}, %{source: :coverage_gap})
    :telemetry.execute([:explorer, :scaled_ui, :integrity_failure], %{count: 5}, %{source: :anchor_break})

    assert counter_value(:scaled_ui_orphan_ui_events_total) == orphan_before + 2
    assert counter_value(:scaled_ui_event_missing_determinations_total) == missing_before + 3
    assert counter_value(:scaled_ui_integrity_failures_total, ["coverage_gap"]) == coverage_before + 4
    assert counter_value(:scaled_ui_integrity_failures_total, ["anchor_break"]) == anchor_before + 5
  end

  test "sets current transfer status and tainted token inventory gauges" do
    assert :ok =
             ScaledUi.set_inventory(%{
               token_transfers: %{"unknown" => 7, "mismatch" => 3, "event_missing" => 2},
               tainted_tokens: 5
             })

    assert Gauge.value(name: :scaled_ui_token_transfers, labels: ["unknown"]) == 7
    assert Gauge.value(name: :scaled_ui_token_transfers, labels: ["mismatch"]) == 3
    assert Gauge.value(name: :scaled_ui_token_transfers, labels: ["event_missing"]) == 2
    assert Gauge.value(name: :scaled_ui_tainted_tokens) == 5
  end

  defp counter_value(name, labels \\ []) do
    case Counter.value(name: name, labels: labels) do
      :undefined -> 0
      value -> value
    end
  end
end
