defmodule Explorer.Chain.ScaledUi.AnnotatorTest do
  use Explorer.DataCase

  import Explorer.Factory

  alias Explorer.Chain.ScaledUi.{Annotator, TokenState}
  alias Explorer.Chain.ScaledUiMultiplierUpdate
  alias Explorer.Repo

  @scale 1_000_000_000_000_000_000

  describe "annotate/2" do
    test "leaves all scaled UI fields nil before the capability boundary" do
      address = insert(:address)
      insert_state(address, 100)

      [annotated] = Annotator.annotate([transfer(address, 99, 1, 10, 15)], batch(%{99 => 99}))

      assert Map.take(annotated, [:ui_value, :ui_multiplier, :ui_amount_status]) == %{
               ui_value: nil,
               ui_multiplier: nil,
               ui_amount_status: nil
             }
    end

    test "marks a paired transfer unknown at the boundary when no timeline exists" do
      address = insert(:address)
      insert_state(address, 100)

      [annotated] = Annotator.annotate([transfer(address, 100, 1, 10, 15)], batch(%{100 => 100}))

      assert annotated.ui_value == d(15)
      assert annotated.ui_multiplier == nil
      assert annotated.ui_amount_status == "unknown"
    end

    test "marks a missing UI event and preserves counter invalidation addresses" do
      address = insert(:address)
      handler_id = "scaled-ui-event-missing-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:explorer, :scaled_ui, :event_missing],
          fn event, measurements, metadata, _config -> send(test_pid, {event, measurements, metadata}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      events = %{
        updates: [updated(address, 100, 1, 100, 0, @scale, 100)],
        capability_rows: [capability(address, 100)],
        block_timestamps: %{100 => DateTime.from_unix!(100)}
      }

      transfer = transfer(address, 100, 2, 10, 10) |> Map.delete(:ui_value)
      [annotated] = Annotator.annotate([transfer], events)

      assert annotated.ui_amount_status == "event_missing"
      assert Decimal.equal?(annotated.ui_multiplier, d(@scale))
      assert annotated.from_address_hash == transfer.from_address_hash
      assert annotated.to_address_hash == transfer.to_address_hash
      assert_receive {[:explorer, :scaled_ui, :event_missing], %{count: 1}, %{}}
    end

    test "uses an in-batch multiplier update for a later transfer" do
      address = insert(:address)

      events = %{
        updates: [updated(address, 100, 1, 100, 0, div(3 * @scale, 2), 100)],
        capability_rows: [capability(address, 100)],
        block_timestamps: %{100 => DateTime.from_unix!(100)}
      }

      [annotated] = Annotator.annotate([transfer(address, 100, 3, 10, 15)], events)

      assert Decimal.equal?(annotated.ui_multiplier, d(div(3 * @scale, 2)))
      assert annotated.ui_amount_status == "ok"
    end

    test "annotates the first batch before capability state is persisted" do
      address = insert(:address)

      events = %{
        updates: [updated(address, 100, 5, 100, 0, @scale, 100)],
        capability_rows: [capability(address, 100)],
        block_timestamps: %{100 => DateTime.from_unix!(100)}
      }

      [before_bootstrap, after_bootstrap] =
        Annotator.annotate(
          [transfer(address, 100, 2, 10, 10), transfer(address, 100, 6, 10, 10)],
          events
        )

      assert before_bootstrap.ui_value == d(10)
      assert before_bootstrap.ui_multiplier == nil
      assert before_bootstrap.ui_amount_status == "unknown"

      assert Decimal.equal?(after_bootstrap.ui_multiplier, d(@scale))
      assert after_bootstrap.ui_amount_status == "ok"
    end

    test "replays persisted and in-batch timeline events together" do
      address = insert(:address)
      insert_state(address, 90)
      insert_updated(address, 90, 1, 90, 0, @scale, 90)

      events = %{
        updates: [updated(address, 100, 1, 100, @scale, 2 * @scale, 100)],
        capability_rows: [],
        block_timestamps: %{100 => DateTime.from_unix!(100)}
      }

      [annotated] = Annotator.annotate([transfer(address, 100, 2, 10, 20)], events)

      assert Decimal.equal?(annotated.ui_multiplier, d(2 * @scale))
      assert annotated.ui_amount_status == "ok"
    end
  end

  defp batch(block_timestamps) do
    %{
      updates: [],
      capability_rows: [],
      block_timestamps: Map.new(block_timestamps, fn {block, timestamp} -> {block, DateTime.from_unix!(timestamp)} end)
    }
  end

  defp transfer(address, block_number, log_index, amount, ui_value) do
    %{
      amount: d(amount),
      block_hash: full_hash(block_number),
      block_number: block_number,
      from_address_hash: "0x3333333333333333333333333333333333333333",
      log_index: log_index,
      to_address_hash: "0x4444444444444444444444444444444444444444",
      token_contract_address_hash: to_string(address.hash),
      token_type: "ERC-20",
      transaction_hash: full_hash(block_number + log_index),
      ui_value: d(ui_value)
    }
  end

  defp capability(address, block_number) do
    %{token_contract_address_hash: to_string(address.hash), capability_block: block_number}
  end

  defp updated(address, block_number, log_index, timestamp, old_multiplier, new_multiplier, effective_at) do
    %{
      token_contract_address_hash: to_string(address.hash),
      transaction_hash: full_hash(block_number + log_index),
      block_hash: full_hash(block_number),
      block_number: block_number,
      block_timestamp: d(timestamp),
      log_index: log_index,
      event_type: "updated",
      old_multiplier: d(old_multiplier),
      new_multiplier: d(new_multiplier),
      effective_at: d(effective_at),
      overwritten_multiplier: nil,
      overwritten_effective_at: nil
    }
  end

  defp insert_state(address, capability_block) do
    %TokenState{}
    |> TokenState.changeset(%{token_contract_address_hash: address.hash, capability_block: capability_block})
    |> Repo.insert!()
  end

  defp insert_updated(address, block_number, log_index, timestamp, old_multiplier, new_multiplier, effective_at) do
    transaction = insert(:transaction) |> with_block(insert(:block, number: block_number))

    %ScaledUiMultiplierUpdate{}
    |> ScaledUiMultiplierUpdate.changeset(%{
      token_contract_address_hash: address.hash,
      transaction_hash: transaction.hash,
      block_hash: transaction.block_hash,
      block_number: block_number,
      block_timestamp: d(timestamp),
      log_index: log_index,
      event_type: "updated",
      old_multiplier: d(old_multiplier),
      new_multiplier: d(new_multiplier),
      effective_at: d(effective_at)
    })
    |> Repo.insert!()
  end

  defp full_hash(value), do: "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")
  defp d(value), do: value |> Integer.to_string() |> Decimal.new()
end
