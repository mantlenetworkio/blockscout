defmodule Explorer.Chain.ScaledUi.BackfillGapTest do
  use Explorer.DataCase

  import Explorer.Factory

  alias Explorer.Repo

  describe "database invariants" do
    test "defaults next_retry_at so a new gap is immediately claimable" do
      address = insert(:address)

      assert {:ok, %{rows: [[next_retry_at, immediately_claimable?]]}} =
               insert_gap(address.hash.bytes, 10, 20, returning: "next_retry_at, next_retry_at <= NOW()")

      assert %NaiveDateTime{} = next_retry_at
      assert immediately_claimable?
    end

    test "rejects a reversed block range" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "scaled_ui_backfill_gaps_valid_range"}}} =
               insert_gap(address.hash.bytes, 20, 10)
    end

    test "rejects a negative retry count" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "scaled_ui_backfill_gaps_retry_count_non_negative"}}} =
               insert_gap(address.hash.bytes, 10, 20, retry_count: -1)
    end

    test "rejects a gap for an address that does not exist" do
      assert {:error,
              %Postgrex.Error{
                postgres: %{constraint: "scaled_ui_backfill_gaps_token_contract_address_hash_fkey"}
              }} =
               insert_gap(address_hash().bytes, 10, 20)
    end
  end

  defp insert_gap(token_hash, from_block, to_block, options \\ []) do
    retry_count = Keyword.get(options, :retry_count, 0)
    returning = Keyword.get(options, :returning, "token_contract_address_hash")

    Repo.query(
      """
      INSERT INTO scaled_ui_backfill_gaps
        (token_contract_address_hash, from_block, to_block, retry_count, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW())
      RETURNING #{returning}
      """,
      [token_hash, from_block, to_block, retry_count]
    )
  end
end
