defmodule Explorer.Repo.Migrations.AddGinIndexToTokensExtensions do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:tokens, [:extensions],
        name: "tokens_extensions_gin_index",
        using: "GIN",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:tokens, [:extensions], name: "tokens_extensions_gin_index"),
      concurrently: true
    )
  end
end
