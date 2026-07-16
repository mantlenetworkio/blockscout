defmodule Explorer.Chain.ScaledUi.TokenStateTest do
  use Explorer.DataCase

  import Explorer.Factory

  alias Explorer.Chain.{ScaledUi.TokenState, ScaledUiMultiplierUpdate, Token}
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

  describe "rebuild/2" do
    test "records a capability boundary before the token is cataloged" do
      address = insert(:address)

      assert Repo.get(Token, address.hash) == nil

      assert {:ok, [address.hash]} ==
               TokenState.rebuild(Repo, [%{token_contract_address_hash: address.hash, capability_block: 50}])

      state = Repo.get!(TokenState, address.hash)
      assert state.capability_block == 50
      assert state.timeline_status == nil
      assert state.base_multiplier == nil
    end

    test "keeps the earliest capability boundary across repeated rebuilds" do
      address = insert(:address)

      assert {:ok, [_]} =
               TokenState.rebuild(Repo, [%{token_contract_address_hash: address.hash, capability_block: 100}])

      assert {:ok, [_]} = TokenState.rebuild(Repo, [%{token_contract_address_hash: address.hash, capability_block: 40}])
      assert {:ok, [_]} = TokenState.rebuild(Repo, [%{token_contract_address_hash: address.hash, capability_block: 80}])

      assert Repo.get!(TokenState, address.hash).capability_block == 40
    end

    test "rebuilds multiplier summary from the complete timeline" do
      address = insert(:address)
      insert_updated(address, 20, 1, 100, 0, 1_000, 100)
      insert_updated(address, 30, 1, 200, 1_000, 2_000, 300)

      assert {:ok, [_]} = TokenState.rebuild(Repo, [%{token_contract_address_hash: address.hash, capability_block: 10}])

      state = Repo.get!(TokenState, address.hash)
      assert state.capability_block == 10
      assert Decimal.equal?(state.base_multiplier, Decimal.new(1_000))
      assert Decimal.equal?(state.pending_multiplier, Decimal.new(2_000))
      assert Decimal.equal?(state.pending_effective_at, Decimal.new(300))
      assert state.timeline_status == "ok"
      assert state.tainted_from_block == nil
    end

    test "persists the first tainted block when timeline anchors break" do
      address = insert(:address)
      handler_id = "scaled-ui-anchor-break-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:explorer, :scaled_ui, :integrity_failure],
          fn event, measurements, metadata, _config -> send(test_pid, {event, measurements, metadata}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      insert_updated(address, 10, 1, 100, 0, 1_000, 100)
      insert_updated(address, 25, 1, 200, 999, 2_000, 200)

      assert {:ok, [_]} = TokenState.rebuild(Repo, [%{token_contract_address_hash: address.hash, capability_block: 10}])

      state = Repo.get!(TokenState, address.hash)
      assert state.timeline_status == "tainted"
      assert state.tainted_from_block == 25
      assert_receive {[:explorer, :scaled_ui, :integrity_failure], %{count: 1}, %{source: :anchor_break}}

      assert {:ok, [_]} = TokenState.rebuild(Repo, [%{token_contract_address_hash: address.hash, capability_block: 10}])
      refute_receive {[:explorer, :scaled_ui, :integrity_failure], _, _}
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

  defp insert_updated(address, block_number, log_index, timestamp, old_multiplier, new_multiplier, effective_at) do
    transaction = insert(:transaction) |> with_block(insert(:block, number: block_number))

    %ScaledUiMultiplierUpdate{}
    |> ScaledUiMultiplierUpdate.changeset(%{
      token_contract_address_hash: address.hash,
      transaction_hash: transaction.hash,
      block_hash: transaction.block_hash,
      block_number: block_number,
      block_timestamp: Decimal.new(timestamp),
      log_index: log_index,
      event_type: "updated",
      old_multiplier: Decimal.new(old_multiplier),
      new_multiplier: Decimal.new(new_multiplier),
      effective_at: Decimal.new(effective_at)
    })
    |> Repo.insert!()
  end
end
