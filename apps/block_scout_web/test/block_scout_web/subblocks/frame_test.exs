defmodule BlockScoutWeb.Subblocks.FrameTest do
  use ExUnit.Case, async: true

  alias BlockScoutWeb.Subblocks.Frame

  @received_at 1_763_020_800_000

  @frame %{
    "payload_id" => "0x0102030405060708",
    "index" => 1,
    "diff" => %{
      "transactions" => ["0x02f8b1", "0x02f8b1"],
      "gas_used" => "0x7459280"
    },
    "metadata" => %{"block_number" => 93_000_000}
  }

  @expected %{
    block_number: 93_000_000,
    index: 1,
    transactions_count: 2,
    gas_used: "122000000",
    received_at: @received_at
  }

  defp json(frame), do: Jason.encode!(frame)

  test "plain JSON" do
    assert Frame.parse(json(@frame), @received_at) == {:ok, @expected}
  end

  test "leading whitespace" do
    assert Frame.parse("\n  " <> json(@frame), @received_at) == {:ok, @expected}
  end

  test "brotli" do
    assert Frame.parse(ExBrotli.compress!(json(@frame)), @received_at) == {:ok, @expected}
  end

  test "index 0 falls back to base" do
    frame =
      @frame
      |> Map.put("index", 0)
      |> Map.put("metadata", %{})
      |> Map.put("base", %{"block_number" => "0x58b1140"})

    assert {:ok, %{block_number: 93_000_000, index: 0}} = Frame.parse(json(frame), @received_at)
  end

  test "hex block_number at index > 0" do
    frame = Map.put(@frame, "metadata", %{"block_number" => "0x58b1140"})

    assert Frame.parse(json(frame), @received_at) == {:error, :invalid_block_number}
  end

  test "missing metadata" do
    assert Frame.parse(json(Map.delete(@frame, "metadata")), @received_at) == {:error, :invalid_block_number}
  end

  # Between 64 KiB and 1 MiB of JSON, the brotli header (window 22, one last meta-block) is the byte `[`.
  test "brotli that starts like JSON" do
    transactions = List.duplicate("0x02f8b1" <> String.duplicate("ab", 200), 200)
    frame = put_in(@frame, ["diff", "transactions"], transactions)
    compressed = ExBrotli.compress!(json(frame))

    assert <<?[, _::binary>> = compressed
    assert {:ok, %{transactions_count: 200}} = Frame.parse(compressed, @received_at)
  end

  test "index beyond any block" do
    assert Frame.parse(json(%{@frame | "index" => 256}), @received_at) == {:error, :invalid_index}
    assert {:ok, %{index: 255}} = Frame.parse(json(%{@frame | "index" => 255}), @received_at)
  end

  test "missing index" do
    assert Frame.parse(json(Map.delete(@frame, "index")), @received_at) == {:error, :invalid_index}
  end

  test "missing transactions" do
    frame = put_in(@frame, ["diff"], Map.delete(@frame["diff"], "transactions"))

    assert Frame.parse(json(frame), @received_at) == {:error, :invalid_transactions}
  end

  test "bad gas_used" do
    frame = put_in(@frame, ["diff", "gas_used"], "zz")

    assert Frame.parse(json(frame), @received_at) == {:error, :invalid_gas_used}
  end

  test "JSON array" do
    assert Frame.parse(Jason.encode!([@frame, @frame]), @received_at) == {:error, :not_an_object}
  end

  test "gzip" do
    assert Frame.parse(:zlib.gzip(json(@frame)), @received_at) == {:error, :undecodable}
  end
end
