defmodule Explorer.Repo.Migrations.CreateScaledUiMultiplierUpdates do
  use Ecto.Migration

  def change do
    create table(:scaled_ui_multiplier_updates, primary_key: false) do
      add(:token_contract_address_hash, references(:addresses, column: :hash, on_delete: :delete_all, type: :bytea),
        null: false,
        primary_key: true
      )

      add(:block_hash, references(:blocks, column: :hash, on_delete: :delete_all, type: :bytea),
        null: false,
        primary_key: true
      )

      add(:log_index, :integer, null: false, primary_key: true)

      add(:transaction_hash, references(:transactions, column: :hash, on_delete: :delete_all, type: :bytea),
        null: false
      )

      add(:block_number, :bigint, null: false)
      add(:block_timestamp, :decimal, precision: 78, scale: 0, null: false)
      add(:event_type, :string, size: 20, null: false)
      add(:old_multiplier, :decimal, precision: 78, scale: 0)
      add(:new_multiplier, :decimal, precision: 78, scale: 0)
      add(:effective_at, :decimal, precision: 78, scale: 0)
      add(:overwritten_multiplier, :decimal, precision: 78, scale: 0)
      add(:overwritten_effective_at, :decimal, precision: 78, scale: 0)

      timestamps(null: false, type: :utc_datetime_usec)
    end

    # event_type domain
    create(
      constraint(:scaled_ui_multiplier_updates, :event_type_known, check: "event_type IN ('updated','overwritten')")
    )

    # 'updated' rows must carry old/new/effective and no overwrite fields
    create(
      constraint(:scaled_ui_multiplier_updates, :updated_row_shape,
        check: """
        event_type <> 'updated' OR
        (old_multiplier IS NOT NULL AND new_multiplier IS NOT NULL AND effective_at IS NOT NULL
         AND overwritten_multiplier IS NULL AND overwritten_effective_at IS NULL)
        """
      )
    )

    # 'overwritten' rows must carry new/effective + overwritten_*
    create(
      constraint(:scaled_ui_multiplier_updates, :overwritten_row_shape,
        check: """
        event_type <> 'overwritten' OR
        (new_multiplier IS NOT NULL AND effective_at IS NOT NULL
         AND overwritten_multiplier IS NOT NULL AND overwritten_effective_at IS NOT NULL)
        """
      )
    )

    # timeline query (token + effective time)
    create(index(:scaled_ui_multiplier_updates, [:token_contract_address_hash, :effective_at]))
    # replay ordering (token + block/log)
    create(index(:scaled_ui_multiplier_updates, [:token_contract_address_hash, :block_number, :log_index]))
    # reorg rollback (by block_hash)
    create(index(:scaled_ui_multiplier_updates, [:block_hash]))
    # event pairing / diagnostics
    create(index(:scaled_ui_multiplier_updates, [:transaction_hash]))
  end
end
