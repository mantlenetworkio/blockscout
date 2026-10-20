defmodule Explorer.Repo.Optimism.Migrations.WidenEIP1559ConfigUpdateParams do
  use Ecto.Migration

  # Both parameters are uint32 on chain, and an integer column holds only up to 2^31 - 1, while a denominator of
  # 2^32 - 1, which freezes the base fee, is a valid setting. The table holds one row per config change, so the rewrite
  # is instant.
  def change do
    alter table(:op_eip1559_config_updates) do
      modify(:base_fee_max_change_denominator, :bigint, from: :integer)
      modify(:elasticity_multiplier, :bigint, from: :integer)
    end
  end
end
