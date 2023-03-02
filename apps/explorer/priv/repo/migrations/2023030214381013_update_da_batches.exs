defmodule Explorer.Repo.Migrations.UpdateDaBatches do
  use Ecto.Migration

  def change do
    alter table(:da_batches) do
      add(:data_commitment, :bytea)
      add(:stakes_from_block_number, :int8)
      add(:init_time, :utc_datetime_usec)
      add(:expire_time, :utc_datetime_usec)
      add(:duration, :int8)
      add(:num_sys, :int8)
      add(:num_par, :int8)
      add(:degree, :int8)
      add(:confirmer, :bytea)
      add(:header, :bytea)
      add(:init_gas_used, :numeric, precision: 100)
      add(:init_block_number, :int8)
      add(:eth_signed, :string)
      add(:eigen_signed, :string)
      add(:signatory_record, :bytea)
      add(:confirm_gas_used, :numeric, precision: 100)
    end
  end
end
