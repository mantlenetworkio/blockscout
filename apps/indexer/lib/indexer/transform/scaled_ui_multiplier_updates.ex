defmodule Indexer.Transform.ScaledUiMultiplierUpdates do
  @moduledoc "Transforms ERC-8056 multiplier logs into timeline and capability rows."

  require Logger

  alias ABI.TypeDecoder
  alias Explorer.Chain.ScaledUi.Events

  @updated_types [{:uint, 256}, {:uint, 256}, {:uint, 256}]
  @overwritten_types [{:uint, 256}, {:uint, 256}, {:uint, 256}, {:uint, 256}]

  def parse(logs, block_timestamps) when is_list(logs) and is_map(block_timestamps) do
    updated_topic = Events.ui_multiplier_updated_topic()
    overwritten_topic = Events.ui_multiplier_change_overwritten_topic()

    Enum.flat_map(logs, fn log ->
      case log.first_topic do
        ^updated_topic ->
          parse_updated(log, block_timestamps)

        ^overwritten_topic ->
          parse_overwritten(log, block_timestamps)

        _topic ->
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

  defp parse_updated(log, block_timestamps) do
    with {:ok, [old_multiplier, new_multiplier, effective_at]} <- decode_data(log.data, @updated_types),
         {:ok, block_timestamp} <- block_timestamp(log, block_timestamps) do
      [
        base_row(log, block_timestamp)
        |> Map.merge(%{
          event_type: "updated",
          old_multiplier: Decimal.new(old_multiplier),
          new_multiplier: Decimal.new(new_multiplier),
          effective_at: Decimal.new(effective_at),
          overwritten_multiplier: nil,
          overwritten_effective_at: nil
        })
      ]
    else
      {:error, reason} -> skip_malformed(log, reason)
    end
  end

  defp parse_overwritten(log, block_timestamps) do
    with {:ok, [overwritten_multiplier, overwritten_effective_at, new_multiplier, effective_at]} <-
           decode_data(log.data, @overwritten_types),
         {:ok, block_timestamp} <- block_timestamp(log, block_timestamps) do
      [
        base_row(log, block_timestamp)
        |> Map.merge(%{
          event_type: "overwritten",
          old_multiplier: nil,
          new_multiplier: Decimal.new(new_multiplier),
          effective_at: Decimal.new(effective_at),
          overwritten_multiplier: Decimal.new(overwritten_multiplier),
          overwritten_effective_at: Decimal.new(overwritten_effective_at)
        })
      ]
    else
      {:error, reason} -> skip_malformed(log, reason)
    end
  end

  defp base_row(log, block_timestamp) do
    %{
      token_contract_address_hash: log.address_hash,
      transaction_hash: log.transaction_hash,
      block_hash: log.block_hash,
      log_index: log.index,
      block_number: log.block_number,
      block_timestamp: block_timestamp
    }
  end

  defp decode_data("0x" <> encoded_data, types) do
    expected_size = 32 * length(types)

    with {:ok, bytes} <- Base.decode16(encoded_data, case: :mixed),
         true <- byte_size(bytes) == expected_size do
      {:ok, TypeDecoder.decode_raw(bytes, types)}
    else
      :error -> {:error, :invalid_hex_data}
      false -> {:error, :invalid_data_length}
    end
  rescue
    error -> {:error, error}
  end

  defp decode_data(_data, _types), do: {:error, :invalid_data}

  defp block_timestamp(log, block_timestamps) do
    case Map.fetch(block_timestamps, log.block_number) do
      {:ok, %DateTime{} = timestamp} -> {:ok, timestamp |> DateTime.to_unix() |> Decimal.new()}
      {:ok, timestamp} when is_integer(timestamp) -> {:ok, Decimal.new(timestamp)}
      :error -> {:error, :missing_block_timestamp}
      {:ok, _timestamp} -> {:error, :invalid_block_timestamp}
    end
  end

  defp skip_malformed(log, reason) do
    Logger.warning(
      "Skipping malformed ERC-8056 multiplier event",
      block_number: log.block_number,
      log_index: log.index,
      reason: inspect(reason)
    )

    []
  end
end
