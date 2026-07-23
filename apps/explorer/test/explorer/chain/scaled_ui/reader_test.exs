defmodule Explorer.Chain.ScaledUi.ReaderTest do
  use Explorer.DataCase

  alias Explorer.Chain.ScaledUi.Reader
  alias Explorer.Chain.ScaledUiMultiplierUpdate
  alias Explorer.Repo

  describe "scaled_amount/3" do
    test "floors without rounding the quotient first" do
      amount = Decimal.new("9999999999999999999999999999")
      state = trusted_state("500000000000000000")

      assert Reader.scaled_amount(amount, state, Decimal.new(0)) ==
               Decimal.new("4999999999999999999999999999")
    end

    test "preserves exact precision at the uint256 boundary" do
      uint256_max = Bitwise.bsl(1, 256) - 1
      amount = Decimal.new(uint256_max)
      state = trusted_state("500000000000000000")
      expected = uint256_max |> div(2) |> Decimal.new()

      assert Reader.scaled_amount(amount, state, Decimal.new(0)) == expected
    end

    test "uses the effective pending multiplier with exact floor semantics" do
      amount = Decimal.new("9999999999999999999999999999")

      state =
        trusted_state("1000000000000000000")
        |> Map.merge(%{
          pending_effective_at: Decimal.new(100),
          pending_multiplier: Decimal.new("500000000000000000")
        })

      assert Reader.scaled_amount(amount, state, Decimal.new(100)) ==
               Decimal.new("4999999999999999999999999999")
    end
  end

  test "returns the canonical head timestamp as Unix seconds" do
    insert(:block, number: 100, consensus: true, timestamp: ~U[2026-07-16 00:00:00Z])
    head = insert(:block, number: 101, consensus: true, timestamp: ~U[2026-07-16 00:01:00Z])
    insert(:block, number: 102, consensus: false, timestamp: ~U[2026-07-16 00:02:00Z])

    assert Reader.canonical_head_timestamp(Repo) == Decimal.new(DateTime.to_unix(head.timestamp))
  end

  test "reads canonical multiplier events and the canonical head in one query" do
    token = insert(:token, extensions: ["ERC-8056"])
    block = insert(:block, number: 100, timestamp: ~U[2026-07-16 00:00:00Z])
    transaction = insert(:transaction) |> with_block(block)

    %ScaledUiMultiplierUpdate{}
    |> ScaledUiMultiplierUpdate.changeset(%{
      block_hash: block.hash,
      block_number: block.number,
      block_timestamp: DateTime.to_unix(block.timestamp),
      effective_at: DateTime.to_unix(block.timestamp),
      event_type: "updated",
      log_index: 0,
      new_multiplier: 2,
      old_multiplier: 1,
      token_contract_address_hash: token.contract_address_hash,
      transaction_hash: transaction.hash
    })
    |> Repo.insert!()

    handler_id = "scaled-ui-reader-snapshot-#{System.unique_integer([:positive])}"
    telemetry_event = Repo.config()[:telemetry_prefix] ++ [:query]
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        telemetry_event,
        &__MODULE__.handle_query/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {[event], head_timestamp} = Reader.canonical_multiplier_updates_snapshot(Repo, token.contract_address_hash)
    assert event.block.hash == block.hash
    assert head_timestamp == Decimal.new(DateTime.to_unix(block.timestamp))

    assert_receive {:query, query}
    assert query =~ ~s(FROM "scaled_ui_multiplier_updates")
    refute_receive {:query, _query}
  end

  def handle_query(_event, _measurements, metadata, pid), do: send(pid, {:query, metadata.query})

  defp trusted_state(base_multiplier) do
    %{
      base_multiplier: Decimal.new(base_multiplier),
      pending_effective_at: nil,
      pending_multiplier: nil,
      timeline_status: "ok"
    }
  end
end
