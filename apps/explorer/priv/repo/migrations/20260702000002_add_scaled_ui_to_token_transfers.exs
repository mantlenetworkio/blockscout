defmodule Explorer.Repo.Migrations.AddScaledUiToTokenTransfers do
  use Ecto.Migration

  def change do
    alter table(:token_transfers) do
      add(:ui_value, :decimal, precision: 78, scale: 0)
      add(:ui_multiplier, :decimal, precision: 78, scale: 0)
      add(:ui_amount_status, :string)
    end

    # token_transfers is a huge table: validate: false constrains only new rows,
    # avoiding a full-table scan lock. Follows the internal_transactions constraint precedent.
    create(
      constraint(
        :token_transfers,
        :ui_amount_status_known,
        check: "ui_amount_status IS NULL OR ui_amount_status IN ('ok','overflow','unknown','mismatch','event_missing')",
        validate: false
      )
    )
  end
end
