defmodule Explorer.Repo.Migrations.AddScaledUiToTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      add(:extensions, {:array, :string})
      add(:scaled_ui_base_multiplier, :decimal, precision: 78, scale: 0)
      add(:scaled_ui_pending_multiplier, :decimal, precision: 78, scale: 0)
      add(:scaled_ui_pending_effective_at, :decimal, precision: 78, scale: 0)
      add(:scaled_ui_capability_block, :bigint)
      add(:scaled_ui_scheduled_ext, :boolean)
      add(:scaled_ui_iface_checked, :boolean, default: false, null: false)
      add(:scaled_ui_timeline_status, :string)
      add(:scaled_ui_tainted_from_block, :bigint)
    end
  end
end
