defmodule Indexer.Prometheus.MetricsTest do
  use ExUnit.Case, async: false

  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Prometheus.ScaledUi
  alias Indexer.Prometheus.Metrics
  alias Prometheus.Metric.Gauge

  setup do
    BackgroundMigrations.set_heavy_indexes_create_token_transfers_scaled_ui_inventory_index_finished(false)

    on_exit(fn ->
      BackgroundMigrations.set_heavy_indexes_create_token_transfers_scaled_ui_inventory_index_finished(false)
    end)

    :ok
  end

  test "does not query or replace inventory gauges before the supporting index is ready" do
    ScaledUi.set_inventory(%{
      token_transfers: %{"unknown" => 7, "mismatch" => 3, "event_missing" => 2},
      tainted_tokens: 5
    })

    handler_id = "scaled-ui-inventory-query-#{System.unique_integer([:positive])}"
    telemetry_event = Explorer.Repo.config()[:telemetry_prefix] ++ [:query]
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        telemetry_event,
        fn _event, _measurements, _metadata, _config -> send(test_pid, :repo_query) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Metrics.set_scaled_ui_inventory()
    refute_receive :repo_query

    assert Gauge.value(name: :scaled_ui_token_transfers, labels: ["unknown"]) == 7
    assert Gauge.value(name: :scaled_ui_token_transfers, labels: ["mismatch"]) == 3
    assert Gauge.value(name: :scaled_ui_token_transfers, labels: ["event_missing"]) == 2
    assert Gauge.value(name: :scaled_ui_tainted_tokens) == 5
  end
end
