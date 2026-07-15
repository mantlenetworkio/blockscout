defmodule Explorer.Chain.ScaledUi.BackfillGapTest do
  use Explorer.DataCase

  import Ecto.Query
  import Explorer.Factory

  alias Explorer.Chain.ScaledUi.BackfillGap
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

  describe "retry leases" do
    test "claims due rows once and applies capped retry state outside the lock transaction" do
      address = insert(:address)
      now = DateTime.utc_now()

      assert {1, nil} =
               BackfillGap.put_ranges(Repo, address.hash, [%{from_block: 10, to_block: 20}], now: now)

      assert [claim] = BackfillGap.claim_due(1, lease_seconds: 60)
      assert claim.from_block == 10
      assert claim.to_block == 20
      assert BackfillGap.claim_due(1, lease_seconds: 60) == []

      assert {1, nil} = BackfillGap.fail_claim(claim, :archive_unavailable, now: now)

      gap = Repo.get_by!(BackfillGap, token_contract_address_hash: address.hash, from_block: 10)
      assert gap.retry_count == 1
      assert gap.last_error == ":archive_unavailable"
      assert DateTime.compare(gap.next_retry_at, now) == :gt
      assert DateTime.diff(gap.next_retry_at, now, :second) <= 60
    end

    test "an expired worker cannot delete a row claimed again" do
      address = insert(:address)
      now = DateTime.utc_now()
      BackfillGap.put_ranges(Repo, address.hash, [%{from_block: 10, to_block: 20}], now: now)

      [old_claim] = BackfillGap.claim_due(1, lease_seconds: 60)

      from(gap in BackfillGap,
        where: gap.token_contract_address_hash == ^address.hash,
        where: gap.from_block == 10
      )
      |> Repo.update_all(set: [next_retry_at: DateTime.add(now, -1, :second)])

      [new_claim] = BackfillGap.claim_due(1, lease_seconds: 60)
      stale_claim = %{old_claim | lease_until: DateTime.add(old_claim.lease_until, -1, :second)}

      assert {0, nil} = BackfillGap.complete_claim(stale_claim)
      assert Repo.get_by(BackfillGap, token_contract_address_hash: address.hash, from_block: 10)

      assert {1, nil} = BackfillGap.complete_claim(new_claim)
      refute Repo.get_by(BackfillGap, token_contract_address_hash: address.hash, from_block: 10)
    end

    test "rediscovery invalidates an outstanding lease before extending its range" do
      address = insert(:address)
      now = DateTime.utc_now()
      BackfillGap.put_ranges(Repo, address.hash, [%{from_block: 10, to_block: 20}], now: now)
      [old_claim] = BackfillGap.claim_due(1, lease_seconds: 60)

      rediscovered_at = DateTime.add(now, 1, :second)
      BackfillGap.put_ranges(Repo, address.hash, [%{from_block: 10, to_block: 30}], now: rediscovered_at)

      assert {0, nil} = BackfillGap.complete_claim(old_claim)

      gap = Repo.get_by!(BackfillGap, token_contract_address_hash: address.hash, from_block: 10)
      assert gap.to_block == 30
      assert gap.next_retry_at == rediscovered_at
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
