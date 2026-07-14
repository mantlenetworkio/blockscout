defmodule Explorer.Repo.Migrations.CreateScaledUiTokenStates do
  use Ecto.Migration

  # 1:1 side table for ERC-8056 per-token state, following the bridged_tokens
  # precedent instead of widening the hot `tokens` table:
  #
  #   * isolates TokenState.rebuild's SELECT ... FOR UPDATE from the frequent
  #     total-supply / counters / market updaters that write `tokens` rows;
  #   * keeps 8056 state out of the 99.9% of token rows that would carry NULLs;
  #   * FK targets addresses(hash), imported in the first serial stage, so
  #     capability/summary upserts never wait for the token catalog.
  def change do
    create table(:scaled_ui_token_states, primary_key: false) do
      add(
        :token_contract_address_hash,
        references(:addresses, column: :hash, type: :bytea, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:base_multiplier, :decimal, precision: 78, scale: 0)
      add(:pending_multiplier, :decimal, precision: 78, scale: 0)
      add(:pending_effective_at, :decimal, precision: 78, scale: 0)
      add(:capability_block, :bigint)
      add(:core_ext, :boolean)
      add(:scheduled_ext, :boolean)
      add(:iface_checked, :boolean, default: false, null: false)
      add(:timeline_status, :string)
      add(:tainted_from_block, :bigint)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(
        :scaled_ui_token_states,
        :timeline_status_known,
        check: "timeline_status IS NULL OR timeline_status IN ('ok','tainted')"
      )
    )

    # Bulk import bypasses changesets, so state-combination invariants are
    # enforced at the DB level too.
    create(
      constraint(
        :scaled_ui_token_states,
        :pending_pair_shape,
        check: "(pending_multiplier IS NULL) = (pending_effective_at IS NULL)"
      )
    )

    # Biconditional: tainted status and tainted_from_block appear together or
    # not at all (an "ok" row must not carry a stale taint block).
    create(
      constraint(
        :scaled_ui_token_states,
        :tainted_block_pair,
        check: "(timeline_status IS NOT DISTINCT FROM 'tainted') = (tainted_from_block IS NOT NULL)"
      )
    )

    create(
      constraint(
        :scaled_ui_token_states,
        :iface_result_shape,
        check:
          "(iface_checked = false AND core_ext IS NULL AND scheduled_ext IS NULL) OR " <>
            "(iface_checked = true AND core_ext IS NOT NULL AND scheduled_ext IS NOT NULL)"
      )
    )
  end
end
