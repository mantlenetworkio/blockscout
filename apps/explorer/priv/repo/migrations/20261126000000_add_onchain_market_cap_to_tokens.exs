# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Repo.Migrations.AddOnchainMarketCapToTokens do
  @moduledoc """
  Adds `tokens.onchain_market_cap`: the token's price times its total supply on
  this chain, a generated column so it follows every price and supply update.
  The decimals bound matches `Explorer.Token.MetadataRetriever`'s cap (78);
  `Token.update/2` can still store larger values, and `power(10, decimals)`
  would overflow on them and fail the whole write.

  Also adds:
  - `tokens_ord_onchain_mcap_mcap_fiat_holder_name_index` for the default token
    list order (`Explorer.Chain.Token.default_sorting/0`);
  - `tokens_lower_symbol_trgm_index` for the symbol substring match in
    `Explorer.Chain.Token.apply_fts_filter/2` (e.g. "mnt" finding "WMNT");
    `pg_trgm` is installed by `20190403080447_add_full_text_search_tokens`.

  The column rewrites the table under an exclusive lock anyway, so the indexes
  are built in the same transaction: the tokens table is small (~10k rows on
  Mantle mainnet) and the migration stays atomic and safe to retry.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE tokens ADD COLUMN onchain_market_cap numeric GENERATED ALWAYS AS (
      CASE
        WHEN decimals BETWEEN 0 AND 78 THEN fiat_value * total_supply / power(10::numeric, decimals)
      END
    ) STORED
    """)

    execute("""
    CREATE INDEX tokens_ord_onchain_mcap_mcap_fiat_holder_name_index ON tokens (
      onchain_market_cap DESC NULLS LAST,
      circulating_market_cap DESC NULLS LAST,
      fiat_value DESC NULLS LAST,
      holder_count DESC NULLS LAST,
      name
    )
    """)

    execute("CREATE INDEX tokens_lower_symbol_trgm_index ON tokens USING GIN (lower(symbol) gin_trgm_ops)")

    # The rewrite leaves the new column and the expression index without statistics. Until
    # autovacuum analyzes the table, the planner overestimates the symbol match and walks the whole
    # sort index for a filtered token list (100k tokens: 242 ms instead of 1 ms).
    execute("ANALYZE tokens")
  end

  def down do
    execute("DROP INDEX IF EXISTS tokens_lower_symbol_trgm_index")
    execute("DROP INDEX IF EXISTS tokens_ord_onchain_mcap_mcap_fiat_holder_name_index")

    alter table(:tokens) do
      remove(:onchain_market_cap)
    end
  end
end
