defmodule BlockScoutWeb.Subblocks.Frame do
  @moduledoc """
  Turns one frame of the OP Stack subblocks (flashblocks) stream into the summary the explorer broadcasts.

  A frame carries one subblock as a JSON object, either as is or brotli-compressed (the ws-proxy compresses when
  started with `--enable-compression`). Only four fields are read; the rest of the payload is ignored.
  """

  @max_index 255

  @type item :: %{
          block_number: non_neg_integer(),
          index: non_neg_integer(),
          transactions_count: non_neg_integer(),
          gas_used: String.t(),
          received_at: non_neg_integer()
        }

  @doc """
  Parses a frame that arrived at `received_at` (milliseconds since the epoch).

  `gas_used` is the block's cumulative gas so far, as a decimal string.
  """
  @spec parse(binary(), non_neg_integer()) :: {:ok, item()} | {:error, atom()}
  def parse(frame, received_at) when is_binary(frame) do
    with {:ok, payload} <- decode(frame),
         {:ok, index} <- index(payload),
         {:ok, block_number} <- block_number(payload, index),
         {:ok, transactions_count} <- transactions_count(payload),
         {:ok, gas_used} <- gas_used(payload) do
      {:ok,
       %{
         block_number: block_number,
         index: index,
         transactions_count: transactions_count,
         gas_used: gas_used,
         received_at: received_at
       }}
    end
  end

  # Plain JSON when the first non-blank byte opens a JSON value, brotli otherwise (the rule the frontend parser uses).
  # A brotli stream of 64 KiB to 1 MiB starts with `[` (0x5B) as well, so what does not parse as JSON is tried as brotli.
  defp decode(frame) do
    case skip_blank(frame) do
      <<char, _::binary>> = json when char in [?{, ?[] ->
        with {:error, :undecodable} <- decode_json(json), do: frame |> decompress() |> decode_json()

      _ ->
        frame |> decompress() |> decode_json()
    end
  end

  defp skip_blank(<<char, rest::binary>>) when char in [?\s, ?\t, ?\r, ?\n], do: skip_blank(rest)
  defp skip_blank(binary), do: binary

  defp decompress(frame) do
    case ExBrotli.decompress(frame) do
      {:ok, json} -> json
      _ -> :undecodable
    end
  end

  defp decode_json(:undecodable), do: {:error, :undecodable}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _} -> {:error, :not_an_object}
      {:error, _} -> {:error, :undecodable}
    end
  end

  # A block has about a dozen slices; an index far beyond that would make every client draw that many cubes.
  defp index(%{"index" => index}) when is_integer(index) and index in 0..@max_index, do: {:ok, index}
  defp index(_), do: {:error, :invalid_index}

  # `metadata.block_number` is a JSON number on every frame; only index 0 also carries `base` with a hex number.
  defp block_number(%{"metadata" => %{"block_number" => number}}, _index) when is_integer(number) and number >= 0,
    do: {:ok, number}

  defp block_number(%{"base" => %{"block_number" => "0x" <> hex}}, 0), do: parse_hex(hex, :invalid_block_number)
  defp block_number(_, _index), do: {:error, :invalid_block_number}

  defp transactions_count(%{"diff" => %{"transactions" => transactions}}) when is_list(transactions),
    do: {:ok, length(transactions)}

  defp transactions_count(_), do: {:error, :invalid_transactions}

  defp gas_used(%{"diff" => %{"gas_used" => "0x" <> hex}}) do
    with {:ok, gas_used} <- parse_hex(hex, :invalid_gas_used), do: {:ok, Integer.to_string(gas_used)}
  end

  defp gas_used(_), do: {:error, :invalid_gas_used}

  defp parse_hex(hex, error) do
    case Integer.parse(hex, 16) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, error}
    end
  end
end
