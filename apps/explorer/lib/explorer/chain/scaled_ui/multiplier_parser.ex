defmodule Explorer.Chain.ScaledUi.MultiplierParser do
  @moduledoc "Parses scheduled ERC-8056 multiplier events without performing database writes."

  alias ABI.TypeDecoder
  alias Explorer.Chain.ScaledUi.Events

  @updated_types [{:uint, 256}, {:uint, 256}, {:uint, 256}]
  @overwritten_types [{:uint, 256}, {:uint, 256}, {:uint, 256}, {:uint, 256}]

  @doc "Parses one multiplier event using its block's Unix timestamp."
  @spec parse_event(map(), DateTime.t() | Decimal.t() | integer()) :: {:ok, map()} | {:error, term()}
  def parse_event(log, block_timestamp) do
    with {:ok, timestamp} <- decimal_timestamp(block_timestamp) do
      do_parse_event(to_string(log.first_topic), log, timestamp)
    end
  end

  defp do_parse_event(topic, log, block_timestamp) do
    cond do
      topic == Events.ui_multiplier_updated_topic() ->
        with {:ok, [old_multiplier, new_multiplier, effective_at]} <- decode_data(log.data, @updated_types) do
          {:ok,
           base_row(log, block_timestamp)
           |> Map.merge(%{
             event_type: "updated",
             old_multiplier: Decimal.new(old_multiplier),
             new_multiplier: Decimal.new(new_multiplier),
             effective_at: Decimal.new(effective_at),
             overwritten_multiplier: nil,
             overwritten_effective_at: nil
           })}
        end

      topic == Events.ui_multiplier_change_overwritten_topic() ->
        with {:ok, [overwritten_multiplier, overwritten_effective_at, new_multiplier, effective_at]} <-
               decode_data(log.data, @overwritten_types) do
          {:ok,
           base_row(log, block_timestamp)
           |> Map.merge(%{
             event_type: "overwritten",
             old_multiplier: nil,
             new_multiplier: Decimal.new(new_multiplier),
             effective_at: Decimal.new(effective_at),
             overwritten_multiplier: Decimal.new(overwritten_multiplier),
             overwritten_effective_at: Decimal.new(overwritten_effective_at)
           })}
        end

      true ->
        {:error, :unsupported_topic}
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

  defp decode_data(data, types) do
    encoded_data = to_string(data)
    expected_size = 32 * length(types)

    with "0x" <> hexadecimal <- encoded_data,
         {:ok, bytes} <- Base.decode16(hexadecimal, case: :mixed),
         true <- byte_size(bytes) == expected_size do
      {:ok, TypeDecoder.decode_raw(bytes, types)}
    else
      :error -> {:error, :invalid_hex_data}
      false -> {:error, :invalid_data_length}
      _ -> {:error, :invalid_data}
    end
  rescue
    error -> {:error, error}
  end

  defp decimal_timestamp(%Decimal{} = timestamp), do: {:ok, timestamp}
  defp decimal_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp |> DateTime.to_unix() |> Decimal.new()}
  defp decimal_timestamp(timestamp) when is_integer(timestamp), do: {:ok, Decimal.new(timestamp)}
  defp decimal_timestamp(_timestamp), do: {:error, :invalid_block_timestamp}
end
