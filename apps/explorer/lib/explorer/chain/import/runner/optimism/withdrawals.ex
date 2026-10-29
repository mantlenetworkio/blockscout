# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Import.Runner.Optimism.Withdrawals do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.OptimismWithdrawal.t/0`.
  """

  require Ecto.Query

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.Import
  alias Explorer.Chain.Optimism.Withdrawal, as: OptimismWithdrawal
  alias Explorer.Prometheus.Instrumenter

  import Ecto.Query, only: [from: 2]

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [OptimismWithdrawal.t()]

  @impl Import.Runner
  def ecto_schema_module, do: OptimismWithdrawal

  @impl Import.Runner
  def option_key, do: :optimism_withdrawals

  @impl Import.Runner
  def imported_table_row do
    %{
      value_type: "[#{ecto_schema_module()}.t()]",
      value_description: "List of `t:#{ecto_schema_module()}.t/0`s"
    }
  end

  @impl Import.Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    Multi.run(multi, :insert_withdrawals, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> insert(repo, changes_list, insert_options) end,
        :block_referencing,
        :optimism_withdrawals,
        :optimism_withdrawals
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map()], %{required(:timeout) => timeout(), required(:timestamps) => Import.timestamps()}) ::
          {:ok, [OptimismWithdrawal.t()]}
          | {:error, [Changeset.t()]}
  def insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options) when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    # Enforce OptimismWithdrawal ShareLocks order (see docs: sharelock.md)
    ordered_changes_list = Enum.sort_by(changes_list, & &1.msg_nonce)

    {:ok, inserted} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        for: OptimismWithdrawal,
        returning: true,
        timeout: timeout,
        timestamps: timestamps,
        conflict_target: :msg_nonce,
        on_conflict: on_conflict
      )

    {:ok, inserted}
  end

  # A re-import of the same withdrawal without a transfer (decoding not configured) keeps the stored one, and one with a
  # transfer replaces it as a whole, so the transfer columns always come from a single decoding. A nonce re-imported
  # for another withdrawal (another hash, after a reorg) never keeps the old transfer.
  defp default_on_conflict do
    from(
      withdrawal in OptimismWithdrawal,
      update: [
        set: [
          # don't update `msg_nonce` as it is a primary key and used for the conflict target
          hash: fragment("EXCLUDED.hash"),
          l2_transaction_hash: fragment("EXCLUDED.l2_transaction_hash"),
          l2_block_number: fragment("EXCLUDED.l2_block_number"),
          message_hash:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.message_hash END",
              withdrawal.hash,
              withdrawal.message_hash
            ),
          transfer_type:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.transfer_type END",
              withdrawal.hash,
              withdrawal.transfer_type
            ),
          transfer_from_address_hash:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.transfer_from_address_hash END",
              withdrawal.hash,
              withdrawal.transfer_from_address_hash
            ),
          transfer_to_address_hash:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.transfer_to_address_hash END",
              withdrawal.hash,
              withdrawal.transfer_to_address_hash
            ),
          l1_token_address_hash:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.l1_token_address_hash END",
              withdrawal.hash,
              withdrawal.l1_token_address_hash
            ),
          l2_token_address_hash:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.l2_token_address_hash END",
              withdrawal.hash,
              withdrawal.l2_token_address_hash
            ),
          transfer_amount:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.transfer_amount END",
              withdrawal.hash,
              withdrawal.transfer_amount
            ),
          mnt_value:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.mnt_value END",
              withdrawal.hash,
              withdrawal.mnt_value
            ),
          eth_value:
            fragment(
              "CASE WHEN EXCLUDED.transfer_type IS NULL AND EXCLUDED.hash = ? THEN ? ELSE EXCLUDED.eth_value END",
              withdrawal.hash,
              withdrawal.eth_value
            ),
          inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", withdrawal.inserted_at),
          updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", withdrawal.updated_at)
        ]
      ],
      where:
        fragment(
          "(EXCLUDED.hash, EXCLUDED.l2_transaction_hash, EXCLUDED.l2_block_number) IS DISTINCT FROM (?, ?, ?)",
          withdrawal.hash,
          withdrawal.l2_transaction_hash,
          withdrawal.l2_block_number
        ) or
          fragment(
            "EXCLUDED.transfer_type IS NOT NULL AND (EXCLUDED.message_hash, EXCLUDED.transfer_type, EXCLUDED.transfer_from_address_hash, EXCLUDED.transfer_to_address_hash, EXCLUDED.l1_token_address_hash, EXCLUDED.l2_token_address_hash, EXCLUDED.transfer_amount, EXCLUDED.mnt_value, EXCLUDED.eth_value) IS DISTINCT FROM (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            withdrawal.message_hash,
            withdrawal.transfer_type,
            withdrawal.transfer_from_address_hash,
            withdrawal.transfer_to_address_hash,
            withdrawal.l1_token_address_hash,
            withdrawal.l2_token_address_hash,
            withdrawal.transfer_amount,
            withdrawal.mnt_value,
            withdrawal.eth_value
          )
    )
  end
end
