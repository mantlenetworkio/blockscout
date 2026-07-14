defmodule Explorer.Repo.Migrations.AddExtensionsToTokens do
  use Ecto.Migration

  # Generic capability markers (e.g. "ERC-8056") queried via GIN for filtering
  # and counters. Extension-specific state lives in dedicated 1:1 side tables
  # (see scaled_ui_token_states), not on this hot table.
  def change do
    alter table(:tokens) do
      add(:extensions, {:array, :string})
    end
  end
end
