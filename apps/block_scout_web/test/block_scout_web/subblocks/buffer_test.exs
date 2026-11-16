defmodule BlockScoutWeb.Subblocks.BufferTest do
  # The buffer owns a named ETS table, so these tests cannot run concurrently.
  use ExUnit.Case, async: false

  alias BlockScoutWeb.Subblocks.Buffer

  defp item(block_number, index, transactions_count \\ 0) do
    %{
      block_number: block_number,
      index: index,
      transactions_count: transactions_count,
      gas_used: "46299",
      received_at: System.system_time(:millisecond) - 2_000 + index * 100
    }
  end

  defp keys(items), do: Enum.map(items, &{&1.block_number, &1.index})

  describe "with a running buffer" do
    setup do
      start_supervised!(Buffer)
      :ok
    end

    test "keeps ascending order" do
      for {block_number, index} <- [{101, 1}, {100, 9}, {101, 0}, {100, 8}], do: Buffer.put(item(block_number, index))

      assert keys(Buffer.recent()) == [{100, 8}, {100, 9}, {101, 0}, {101, 1}]
    end

    test "trims to 60" do
      for index <- 0..60, do: Buffer.put(item(100 + div(index, 10), rem(index, 10)))

      recent = Buffer.recent()
      assert length(recent) == 60
      refute {100, 0} in keys(recent)
      assert List.last(keys(recent)) == {106, 0}
    end

    test "replaces a repeated key" do
      assert Buffer.put(item(100, 3, 1)) == :new
      assert Buffer.put(item(100, 3, 2)) == :replaced

      assert [%{block_number: 100, index: 3, transactions_count: 2}] = Buffer.recent()
    end

    test "unchanged duplicate" do
      assert Buffer.put(item(100, 3, 1)) == :new
      assert Buffer.put(item(100, 3, 1)) == :unchanged
      assert length(Buffer.recent()) == 1
    end

    test "a re-sent identical subblock keeps its first arrival time" do
      first = item(100, 3, 1)

      assert Buffer.put(first) == :new
      assert Buffer.put(%{first | received_at: first.received_at + 500}) == :unchanged
      assert Buffer.recent() == [first]
    end

    test "nothing while the feed is stale" do
      Buffer.put(%{item(100, 3) | received_at: System.system_time(:millisecond) - 6_000})

      assert Buffer.recent() == []
    end

    test "older items come along while the newest one is fresh" do
      Buffer.put(%{item(100, 3) | received_at: System.system_time(:millisecond) - 6_000})
      Buffer.put(item(100, 4))

      assert keys(Buffer.recent()) == [{100, 3}, {100, 4}]
    end

    test "items from before an outage are left out" do
      Buffer.put(%{item(100, 3) | received_at: System.system_time(:millisecond) - 20_000})
      Buffer.put(item(120, 1))

      assert keys(Buffer.recent()) == [{120, 1}]
    end

    test "empty" do
      assert Buffer.recent() == []
    end
  end

  test "no buffer running" do
    assert Buffer.recent() == []
  end
end
