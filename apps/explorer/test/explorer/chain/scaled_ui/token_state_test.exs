defmodule Explorer.Chain.ScaledUi.TokenStateTest do
  use Explorer.DataCase

  import Explorer.Factory

  alias Explorer.Chain.ScaledUi.TokenState
  alias Explorer.Repo

  describe "changeset/2" do
    test "casts and persists the full field set" do
      address = insert(:address)

      params = %{
        token_contract_address_hash: address.hash,
        base_multiplier: Decimal.new("1000000000000000000"),
        pending_multiplier: Decimal.new("2000000000000000000"),
        pending_effective_at: Decimal.new("1900000000"),
        capability_block: 100,
        core_ext: true,
        scheduled_ext: true,
        iface_checked: true,
        timeline_status: "tainted",
        tainted_from_block: 250
      }

      changeset = TokenState.changeset(%TokenState{}, params)
      assert changeset.valid?
      {:ok, _} = Repo.insert(changeset)

      reloaded = Repo.get_by(TokenState, token_contract_address_hash: address.hash)
      assert Decimal.equal?(reloaded.base_multiplier, Decimal.new("1000000000000000000"))
      assert Decimal.equal?(reloaded.pending_multiplier, Decimal.new("2000000000000000000"))
      assert Decimal.equal?(reloaded.pending_effective_at, Decimal.new("1900000000"))
      assert reloaded.capability_block == 100
      assert reloaded.core_ext == true
      assert reloaded.scheduled_ext == true
      assert reloaded.iface_checked == true
      assert reloaded.timeline_status == "tainted"
      assert reloaded.tainted_from_block == 250
    end

    test "iface_checked defaults to false at struct and DB level" do
      address = insert(:address)
      assert %TokenState{}.iface_checked == false

      {:ok, _} = Repo.insert(TokenState.changeset(%TokenState{}, %{token_contract_address_hash: address.hash}))
      reloaded = Repo.get_by(TokenState, token_contract_address_hash: address.hash)
      assert reloaded.iface_checked == false
    end

    test "persists maximum uint256 multiplier without precision loss" do
      address = insert(:address)
      max_uint256 = Decimal.new(Integer.to_string(Bitwise.<<<(1, 256) - 1))

      {:ok, _} =
        Repo.insert(
          TokenState.changeset(%TokenState{}, %{
            token_contract_address_hash: address.hash,
            base_multiplier: max_uint256
          })
        )

      reloaded = Repo.get_by(TokenState, token_contract_address_hash: address.hash)
      assert Decimal.equal?(reloaded.base_multiplier, max_uint256)
    end

    test "rejects invalid timeline_status" do
      address = insert(:address)

      refute TokenState.changeset(%TokenState{}, %{
               token_contract_address_hash: address.hash,
               timeline_status: "bogus"
             }).valid?
    end

    test "rejects an incomplete pending multiplier pair" do
      address = insert(:address)

      changeset =
        TokenState.changeset(%TokenState{}, %{
          token_contract_address_hash: address.hash,
          pending_multiplier: Decimal.new(1)
        })

      refute changeset.valid?
      assert {_message, _metadata} = changeset.errors[:pending_effective_at]
    end

    test "rejects an inconsistent tainted status and block" do
      address = insert(:address)

      missing_block =
        TokenState.changeset(%TokenState{}, %{
          token_contract_address_hash: address.hash,
          timeline_status: "tainted"
        })

      stale_block =
        TokenState.changeset(%TokenState{}, %{
          token_contract_address_hash: address.hash,
          timeline_status: "ok",
          tainted_from_block: 10
        })

      refute missing_block.valid?
      refute stale_block.valid?
      assert {_message, _metadata} = missing_block.errors[:tainted_from_block]
      assert {_message, _metadata} = stale_block.errors[:tainted_from_block]
    end

    test "rejects interface results that disagree with iface_checked" do
      address = insert(:address)

      unchecked_with_result =
        TokenState.changeset(%TokenState{}, %{
          token_contract_address_hash: address.hash,
          core_ext: true
        })

      checked_with_incomplete_results =
        TokenState.changeset(%TokenState{}, %{
          token_contract_address_hash: address.hash,
          iface_checked: true,
          core_ext: true
        })

      refute unchecked_with_result.valid?
      refute checked_with_incomplete_results.valid?
      assert {_message, _metadata} = unchecked_with_result.errors[:iface_checked]
      assert {_message, _metadata} = checked_with_incomplete_results.errors[:scheduled_ext]
    end

    test "rejects rows whose address does not exist (FK)" do
      {:error, changeset} =
        %TokenState{}
        |> TokenState.changeset(%{token_contract_address_hash: address_hash()})
        |> Repo.insert()

      assert {"does not exist", _} = changeset.errors[:token_contract_address_hash]
    end
  end

  describe "DB combination CHECKs (raw SQL bypassing changeset)" do
    # Bulk import bypasses changesets; each invariant must be enforced by the
    # database itself. A legal-data pass only proves the constraint does not
    # over-reject; these negative cases prove it actually rejects bad rows.

    defp raw_insert(address, extra_cols, extra_vals) do
      cols = Enum.join(["token_contract_address_hash", "inserted_at", "updated_at" | extra_cols], ", ")
      placeholders = Enum.map_join(1..(3 + length(extra_vals)), ", ", &"$#{&1}")
      now = DateTime.utc_now()

      Repo.query(
        "INSERT INTO scaled_ui_token_states (#{cols}) VALUES (#{placeholders})",
        [address.hash.bytes, now, now | extra_vals]
      )
    end

    test "rejects an unknown timeline status" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "timeline_status_known"}}} =
               raw_insert(address, ["timeline_status"], ["bogus"])
    end

    test "rejects pending multiplier without effective_at" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "pending_pair_shape"}}} =
               raw_insert(address, ["pending_multiplier"], [Decimal.new(1)])
    end

    test "rejects ok status with stale tainted_from_block" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "tainted_block_pair"}}} =
               raw_insert(address, ["timeline_status", "tainted_from_block"], ["ok", 10])
    end

    test "rejects tainted status without tainted_from_block" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "tainted_block_pair"}}} =
               raw_insert(address, ["timeline_status"], ["tainted"])
    end

    test "rejects iface results without iface_checked" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "iface_result_shape"}}} =
               raw_insert(address, ["core_ext"], [true])
    end

    test "rejects iface_checked=true with incomplete results" do
      address = insert(:address)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "iface_result_shape"}}} =
               raw_insert(address, ["iface_checked", "core_ext"], [true, true])
    end
  end
end
