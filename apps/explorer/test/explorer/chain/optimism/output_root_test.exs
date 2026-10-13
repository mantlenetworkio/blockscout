defmodule Explorer.Chain.Optimism.OutputRootTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Application.Constants
    alias Explorer.Chain.Optimism.OutputRoot
    alias Explorer.PagingOptions

    import Ecto.Query, only: [from: 2]

    describe "by_index/2" do
      test "finds a root by its index and rejects out-of-range indexes" do
        root = insert(:op_output_root, l2_output_index: 3)

        assert %OutputRoot{l2_output_index: 3} = OutputRoot.by_index(3)
        assert OutputRoot.by_index(root.l2_output_index + 1) == nil
        assert OutputRoot.by_index(-1) == nil
        assert OutputRoot.by_index(9_223_372_036_854_775_808) == nil
      end
    end

    describe "block_range/2" do
      test "starts right after the previous root" do
        insert(:op_output_root, l2_output_index: 4, l2_block_number: 2_000_100)
        root = insert(:op_output_root, l2_output_index: 5, l2_block_number: 2_000_110)

        assert OutputRoot.block_range(root) == {2_000_101, 2_000_110}
      end

      test "is open when the previous index is missing, even if an older root exists" do
        insert(:op_output_root, l2_output_index: 3, l2_block_number: 2_000_090)
        root = insert(:op_output_root, l2_output_index: 5, l2_block_number: 2_000_110)

        assert OutputRoot.block_range(root) == {nil, 2_000_110}
      end

      test "uses the oracle starting block for index 0" do
        Constants.set_constant_value(OutputRoot.starting_block_number_constant(), "2000000")
        root = insert(:op_output_root, l2_output_index: 0, l2_block_number: 2_000_050)

        assert OutputRoot.block_range(root) == {2_000_001, 2_000_050}
      end

      test "is open for index 0 when the starting block is unknown" do
        root = insert(:op_output_root, l2_output_index: 0, l2_block_number: 2_000_050)

        assert OutputRoot.block_range(root) == {nil, 2_000_050}
      end
    end

    describe "l1_finality/2" do
      test "is nil while no heads are stored" do
        assert OutputRoot.l1_finality(1) == nil
      end

      test "classifies by the stored heads, boundaries inclusive" do
        Constants.set_constant_value(OutputRoot.l1_safe_block_number_constant(), "100")
        Constants.set_constant_value(OutputRoot.l1_finalized_block_number_constant(), "90")

        assert OutputRoot.l1_finality(1) == :finalized
        assert OutputRoot.l1_finality(90) == :finalized
        assert OutputRoot.l1_finality(91) == :safe
        assert OutputRoot.l1_finality(100) == :safe
        assert OutputRoot.l1_finality(101) == :unsafe
      end
    end

    describe "details/2" do
      test "returns the range, counts, finality and challenge period end" do
        Constants.set_constant_value(OutputRoot.finalization_period_constant(), "3600")

        insert(:op_output_root, l2_output_index: 7, l2_block_number: 2_000_300)

        root =
          insert(:op_output_root,
            l2_output_index: 8,
            l2_block_number: 2_000_303,
            l1_block_number: 50,
            l1_timestamp: ~U[2026-01-01 00:00:00.000000Z]
          )

        [first | _] = blocks = for n <- 2_000_301..2_000_303, do: insert(:block, number: n)
        :transaction |> insert() |> with_block(first)
        :transaction |> insert() |> with_block(List.last(blocks))
        :transaction |> insert() |> with_block(insert(:block, number: 2_000_304))
        Constants.set_constant_value(OutputRoot.l1_finalized_block_number_constant(), "50")

        assert %{
                 l2_start_block_number: 2_000_301,
                 l2_end_block_number: 2_000_303,
                 blocks_count: 3,
                 transactions_count: 2,
                 l1_finality: :finalized,
                 challenge_period_end: ~U[2026-01-01 01:00:00.000000Z]
               } = OutputRoot.details(root)
      end

      test "leaves counts empty when the range is unknown" do
        root = insert(:op_output_root, l2_output_index: 12, l2_block_number: 2_000_400)

        assert %{l2_start_block_number: nil, blocks_count: nil, transactions_count: nil} = OutputRoot.details(root)
      end

      test "leaves the challenge period end empty while the indexer has not stored the finalization period" do
        root = insert(:op_output_root, l2_output_index: 13, l2_block_number: 2_000_500)

        assert %{challenge_period_end: nil} = OutputRoot.details(root)
      end
    end

    describe "count_within/3" do
      test "counts the rows when the query finishes in time" do
        :transaction |> insert() |> with_block(insert(:block, number: 2_000_600))

        query = from(t in Explorer.Chain.Transaction, where: t.block_number == 2_000_600)

        assert OutputRoot.count_within(query, 5_000) == 1
      end

      test "returns nil when Postgres cancels the count at the timeout" do
        :transaction |> insert() |> with_block(insert(:block, number: 2_000_700))

        # pg_sleep makes the count take ~200 ms per row, well past the 50 ms timeout
        query =
          from(t in Explorer.Chain.Transaction,
            where: t.block_number == 2_000_700 and fragment("pg_sleep(0.2) IS NOT NULL")
          )

        assert OutputRoot.count_within(query, 50) == nil
      end
    end

    describe "blocks_in_range/3" do
      test "returns consensus blocks of the inclusive range, newest first" do
        for n <- 2_000_200..2_000_205, do: insert(:block, number: n)
        insert(:block, number: 2_000_203, consensus: false)

        numbers =
          2_000_201
          |> OutputRoot.blocks_in_range(2_000_204, paging_options: %PagingOptions{page_size: 10})
          |> Enum.map(& &1.number)

        assert numbers == [2_000_204, 2_000_203, 2_000_202, 2_000_201]
      end

      test "returns at most a page of blocks strictly below the page key" do
        for n <- 2_000_200..2_000_205, do: insert(:block, number: n)

        numbers =
          2_000_201
          |> OutputRoot.blocks_in_range(2_000_204, paging_options: %PagingOptions{key: {2_000_204}, page_size: 2})
          |> Enum.map(& &1.number)

        assert numbers == [2_000_203, 2_000_202]
      end
    end
  end
end
