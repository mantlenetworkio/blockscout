defmodule Indexer.Transform.ScaledUiMultiplierUpdates do
  @moduledoc "Transforms ERC-8056 multiplier logs into timeline and capability rows."

  require Logger

  alias Explorer.Chain.ScaledUi.{Events, MultiplierParser}

  def parse(logs, block_timestamps) when is_list(logs) and is_map(block_timestamps) do
    updated_topic = Events.ui_multiplier_updated_topic()
    overwritten_topic = Events.ui_multiplier_change_overwritten_topic()

    Enum.flat_map(logs, fn log ->
      if log.first_topic in [updated_topic, overwritten_topic] do
        parse_event(log, block_timestamps)
      else
        []
      end
    end)
  end

  def capability_rows(logs) when is_list(logs) do
    topics = MapSet.new(Events.all_topics())

    logs
    |> Enum.reduce(%{}, fn log, rows ->
      if MapSet.member?(topics, log.first_topic) do
        Map.update(rows, log.address_hash, log.block_number, &min(&1, log.block_number))
      else
        rows
      end
    end)
    |> Enum.map(fn {token_hash, block_number} ->
      %{token_contract_address_hash: token_hash, capability_block: block_number}
    end)
    |> Enum.sort_by(& &1.token_contract_address_hash)
  end

  defp parse_event(log, block_timestamps) do
    case Map.fetch(block_timestamps, log.block_number) do
      {:ok, timestamp} ->
        case MultiplierParser.parse_event(log, timestamp) do
          {:ok, update} -> [update]
          {:error, reason} -> skip_malformed(log, reason)
        end

      :error ->
        skip_malformed(log, :missing_block_timestamp)
    end
  end

  defp skip_malformed(log, reason) do
    Logger.warning(
      "Skipping malformed ERC-8056 multiplier event at block #{log.block_number}, " <>
        "log #{log.index}: #{inspect(reason)}"
    )

    []
  end
end
