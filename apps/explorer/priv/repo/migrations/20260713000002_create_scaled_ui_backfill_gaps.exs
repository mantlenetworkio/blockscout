defmodule Explorer.Repo.Migrations.CreateScaledUiBackfillGaps do
  use Ecto.Migration

  # Per-token log-range gaps discovered during backfill when Archive RPC was
  # unavailable. Rows survive migration completion so gaps
  # stay retryable; backfill is only "done" for a token when its gaps are
  # cleared. Workers claim rows with FOR UPDATE SKIP LOCKED and honour
  # exponential backoff on next_retry_at.
  def up do
    create table(:scaled_ui_backfill_gaps, primary_key: false) do
      add(
        :token_contract_address_hash,
        references(:addresses, column: :hash, type: :bytea, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:from_block, :bigint, null: false, primary_key: true)
      add(:to_block, :bigint, null: false)
      add(:retry_count, :integer, null: false, default: 0)
      add(:next_retry_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:last_error, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:scaled_ui_backfill_gaps, [:next_retry_at]))

    create(constraint(:scaled_ui_backfill_gaps, :scaled_ui_backfill_gaps_valid_range, check: "from_block <= to_block"))

    create(
      constraint(:scaled_ui_backfill_gaps, :scaled_ui_backfill_gaps_retry_count_non_negative, check: "retry_count >= 0")
    )
  end

  def down do
    drop(table(:scaled_ui_backfill_gaps))
  end
end
