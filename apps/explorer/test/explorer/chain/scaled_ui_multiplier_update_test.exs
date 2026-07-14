defmodule Explorer.Chain.ScaledUiMultiplierUpdateTest do
  use Explorer.DataCase

  alias Explorer.Chain.ScaledUiMultiplierUpdate
  alias Explorer.Repo

  defp base_params do
    token_address = insert(:contract_address)
    transaction = insert(:transaction)
    block = insert(:block)

    %{
      token_contract_address_hash: token_address.hash,
      transaction_hash: transaction.hash,
      block_number: block.number,
      block_hash: block.hash,
      log_index: 3,
      block_timestamp: Decimal.new("1750000000")
    }
  end

  describe "changeset/2 valid rows" do
    test "inserts a valid 'updated' row (incl. init sentinel old_multiplier=0)" do
      params =
        Map.merge(base_params(), %{
          event_type: "updated",
          old_multiplier: Decimal.new("0"),
          new_multiplier: Decimal.new("1000000000000000000"),
          effective_at: Decimal.new("1750000000")
        })

      {:ok, row} = Repo.insert(ScaledUiMultiplierUpdate.changeset(%ScaledUiMultiplierUpdate{}, params))
      assert row.event_type == "updated"
      assert Decimal.equal?(row.old_multiplier, Decimal.new("0"))
    end

    test "inserts a valid 'overwritten' row" do
      params =
        Map.merge(base_params(), %{
          event_type: "overwritten",
          new_multiplier: Decimal.new("3000000000000000000"),
          effective_at: Decimal.new("1750000200"),
          overwritten_multiplier: Decimal.new("2000000000000000000"),
          overwritten_effective_at: Decimal.new("1750000100")
        })

      {:ok, row} = Repo.insert(ScaledUiMultiplierUpdate.changeset(%ScaledUiMultiplierUpdate{}, params))
      assert row.event_type == "overwritten"
      assert Decimal.equal?(row.overwritten_multiplier, Decimal.new("2000000000000000000"))
    end

    test "persists maximum uint256 effective_at without loss" do
      max_uint256 = Decimal.new(Integer.to_string(Bitwise.<<<(1, 256) - 1))

      params =
        Map.merge(base_params(), %{
          event_type: "updated",
          old_multiplier: Decimal.new("1000000000000000000"),
          new_multiplier: Decimal.new("1000000000000000000"),
          effective_at: max_uint256
        })

      {:ok, row} = Repo.insert(ScaledUiMultiplierUpdate.changeset(%ScaledUiMultiplierUpdate{}, params))
      assert Decimal.equal?(row.effective_at, max_uint256)
    end
  end

  describe "changeset/2 rejections" do
    test "rejects unknown event_type" do
      changeset =
        ScaledUiMultiplierUpdate.changeset(%ScaledUiMultiplierUpdate{}, Map.put(base_params(), :event_type, "bogus"))

      refute changeset.valid?
      assert %{event_type: _} = changeset_errors(changeset)
    end

    test "rejects incomplete 'updated' row (missing new_multiplier/effective_at)" do
      changeset =
        ScaledUiMultiplierUpdate.changeset(
          %ScaledUiMultiplierUpdate{},
          Map.merge(base_params(), %{event_type: "updated", old_multiplier: Decimal.new("0")})
        )

      refute changeset.valid?
      assert %{new_multiplier: _} = changeset_errors(changeset)
    end

    test "rejects an 'updated' row missing old_multiplier" do
      changeset =
        ScaledUiMultiplierUpdate.changeset(
          %ScaledUiMultiplierUpdate{},
          Map.merge(base_params(), %{
            event_type: "updated",
            new_multiplier: Decimal.new("1000000000000000000"),
            effective_at: Decimal.new("1750000000")
          })
        )

      refute changeset.valid?
      assert %{old_multiplier: _} = changeset_errors(changeset)
    end

    test "rejects incomplete 'overwritten' row (missing overwritten_* fields)" do
      changeset =
        ScaledUiMultiplierUpdate.changeset(
          %ScaledUiMultiplierUpdate{},
          Map.merge(base_params(), %{
            event_type: "overwritten",
            new_multiplier: Decimal.new("3000000000000000000"),
            effective_at: Decimal.new("1750000200")
          })
        )

      refute changeset.valid?
      assert %{overwritten_multiplier: _} = changeset_errors(changeset)
    end

    test "rejects an 'overwritten' row carrying old_multiplier" do
      changeset =
        ScaledUiMultiplierUpdate.changeset(
          %ScaledUiMultiplierUpdate{},
          Map.merge(base_params(), %{
            event_type: "overwritten",
            old_multiplier: Decimal.new("1000000000000000000"),
            new_multiplier: Decimal.new("3000000000000000000"),
            effective_at: Decimal.new("1750000200"),
            overwritten_multiplier: Decimal.new("2000000000000000000"),
            overwritten_effective_at: Decimal.new("1750000100")
          })
        )

      refute changeset.valid?
      assert %{old_multiplier: _} = changeset_errors(changeset)
    end

    test "rejects an 'updated' row carrying overwrite fields" do
      changeset =
        ScaledUiMultiplierUpdate.changeset(
          %ScaledUiMultiplierUpdate{},
          Map.merge(base_params(), %{
            event_type: "updated",
            old_multiplier: Decimal.new("1000000000000000000"),
            new_multiplier: Decimal.new("3000000000000000000"),
            effective_at: Decimal.new("1750000200"),
            overwritten_multiplier: Decimal.new("2000000000000000000"),
            overwritten_effective_at: Decimal.new("1750000100")
          })
        )

      refute changeset.valid?
      assert %{overwritten_multiplier: _} = changeset_errors(changeset)
      assert %{overwritten_effective_at: _} = changeset_errors(changeset)
    end
  end

  describe "DB constraints (bulk-import path bypasses changeset)" do
    test "DB CHECK rejects a structurally-invalid 'updated' row inserted raw" do
      p = base_params()

      assert {:error, %Postgrex.Error{postgres: %{constraint: "updated_row_shape"}}} =
               Repo.query(
                 """
                 INSERT INTO scaled_ui_multiplier_updates
                   (token_contract_address_hash, transaction_hash, block_number, block_hash, log_index,
                    block_timestamp, event_type, inserted_at, updated_at)
                 VALUES ($1,$2,$3,$4,$5,$6,'updated',NOW(),NOW())
                 """,
                 [
                   p.token_contract_address_hash.bytes,
                   p.transaction_hash.bytes,
                   p.block_number,
                   p.block_hash.bytes,
                   p.log_index,
                   Decimal.to_integer(p.block_timestamp)
                 ]
               )
    end

    test "DB CHECK rejects an unknown event_type" do
      p = base_params()

      assert {:error, %Postgrex.Error{postgres: %{constraint: "event_type_known"}}} =
               Repo.query(
                 """
                 INSERT INTO scaled_ui_multiplier_updates
                   (token_contract_address_hash, transaction_hash, block_number, block_hash, log_index,
                    block_timestamp, event_type, old_multiplier, new_multiplier, effective_at,
                    inserted_at, updated_at)
                 VALUES ($1,$2,$3,$4,$5,$6,'bogus',$7,$8,$9,NOW(),NOW())
                 """,
                 [
                   p.token_contract_address_hash.bytes,
                   p.transaction_hash.bytes,
                   p.block_number,
                   p.block_hash.bytes,
                   p.log_index,
                   Decimal.to_integer(p.block_timestamp),
                   Decimal.new("0"),
                   Decimal.new("1000000000000000000"),
                   Decimal.new("1750000000")
                 ]
               )
    end

    test "DB CHECK rejects an 'updated' row carrying overwrite fields" do
      p = base_params()

      assert {:error, %Postgrex.Error{postgres: %{constraint: "updated_row_shape"}}} =
               Repo.query(
                 """
                 INSERT INTO scaled_ui_multiplier_updates
                   (token_contract_address_hash, transaction_hash, block_number, block_hash, log_index,
                    block_timestamp, event_type, old_multiplier, new_multiplier, effective_at,
                    overwritten_multiplier, overwritten_effective_at, inserted_at, updated_at)
                 VALUES ($1,$2,$3,$4,$5,$6,'updated',$7,$8,$9,$10,$11,NOW(),NOW())
                 """,
                 [
                   p.token_contract_address_hash.bytes,
                   p.transaction_hash.bytes,
                   p.block_number,
                   p.block_hash.bytes,
                   p.log_index,
                   Decimal.to_integer(p.block_timestamp),
                   Decimal.new("1000000000000000000"),
                   Decimal.new("3000000000000000000"),
                   Decimal.new("1750000200"),
                   Decimal.new("2000000000000000000"),
                   Decimal.new("1750000100")
                 ]
               )
    end

    test "DB CHECK rejects an 'overwritten' row carrying old_multiplier" do
      p = base_params()

      assert {:error, %Postgrex.Error{postgres: %{constraint: "overwritten_row_shape"}}} =
               Repo.query(
                 """
                 INSERT INTO scaled_ui_multiplier_updates
                   (token_contract_address_hash, transaction_hash, block_number, block_hash, log_index,
                    block_timestamp, event_type, old_multiplier, new_multiplier, effective_at,
                    overwritten_multiplier, overwritten_effective_at, inserted_at, updated_at)
                 VALUES ($1,$2,$3,$4,$5,$6,'overwritten',$7,$8,$9,$10,$11,NOW(),NOW())
                 """,
                 [
                   p.token_contract_address_hash.bytes,
                   p.transaction_hash.bytes,
                   p.block_number,
                   p.block_hash.bytes,
                   p.log_index,
                   Decimal.to_integer(p.block_timestamp),
                   Decimal.new("1000000000000000000"),
                   Decimal.new("3000000000000000000"),
                   Decimal.new("1750000200"),
                   Decimal.new("2000000000000000000"),
                   Decimal.new("1750000100")
                 ]
               )
    end

    test "duplicate composite PK is rejected" do
      params =
        Map.merge(base_params(), %{
          event_type: "updated",
          old_multiplier: Decimal.new("0"),
          new_multiplier: Decimal.new("1000000000000000000"),
          effective_at: Decimal.new("1750000000")
        })

      {:ok, _} = Repo.insert(ScaledUiMultiplierUpdate.changeset(%ScaledUiMultiplierUpdate{}, params))

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(ScaledUiMultiplierUpdate.changeset(%ScaledUiMultiplierUpdate{}, params))
      end
    end
  end
end
