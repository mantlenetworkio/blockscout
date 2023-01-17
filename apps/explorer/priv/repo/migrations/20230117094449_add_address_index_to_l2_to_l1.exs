defmodule Explorer.Repo.Migrations.AddAddressIndexToL2ToL1 do
  use Ecto.Migration

  def change do
    create(index(:l2_to_l1, [:l2_token, :from, :to]))
  end
end
