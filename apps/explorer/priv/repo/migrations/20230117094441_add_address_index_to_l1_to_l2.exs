defmodule Explorer.Repo.Migrations.AddAddressIndexToL1ToL2 do
  use Ecto.Migration

  def change do
    create(index(:l1_to_l2, [:l2_token, :from, :to, :type]))
  end
end
