defmodule Explorer.Chain.Optimism.EIP1559ConfigUpdateTest do
  use Explorer.DataCase, async: false

  alias Explorer.Chain
  alias Explorer.Chain.Optimism.EIP1559ConfigUpdate

  # Both parameters are uint32 on chain; a denominator of 2^32 - 1 freezes the base fee.
  @max_uint32 4_294_967_295

  test "imports and reads parameters across the whole uint32 range" do
    assert {:ok, _} =
             Chain.import(%{
               optimism_eip1559_config_updates: %{
                 params: [
                   %{
                     l2_block_number: 3_629_775,
                     l2_block_hash: "0x" <> String.duplicate("c8", 32),
                     base_fee_max_change_denominator: @max_uint32,
                     elasticity_multiplier: @max_uint32,
                     min_base_fee: 50_000_000_000
                   }
                 ]
               },
               timeout: :infinity
             })

    assert EIP1559ConfigUpdate.actual_config_for_block(3_629_776) == {@max_uint32, @max_uint32, 50_000_000_000}
  end
end
