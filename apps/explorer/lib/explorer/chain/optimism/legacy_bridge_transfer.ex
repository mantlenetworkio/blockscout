defmodule Explorer.Chain.Optimism.LegacyBridgeTransfer do
  @moduledoc """
    Models a Mantle v1 (pre-Bedrock) bridge message: a deposit or withdrawal of the legacy cross-domain messengers,
    rebuilt from chain data by `Indexer.Fetcher.Optimism.LegacyBridge` and decoded by
    `Explorer.Chain.Optimism.LegacyBridgeMessage`.

    The rows live apart from `op_deposits` / `op_withdrawals`, so that the upstream fetchers and explorer pages never
    see them; the bridge history (`Explorer.Chain.Optimism.BridgeHistory`) serves them once they are validated.
  """

  use Explorer.Schema

  alias Explorer.Chain.{Data, Hash}
  alias Explorer.Repo

  @typedoc """
    * `direction` - `deposit` (L1 to L2) or `withdrawal` (L2 to L1).
    * `nonce` - The legacy messenger nonce (version 0).
    * `transaction_hash`, `block_number`, `timestamp` - The initiating transaction: on L1 for a deposit, on L2 for a
      withdrawal.
    * `transfer_type`, `transfer_from_address_hash`, `transfer_to_address_hash`, `l1_token_address_hash`,
      `l2_token_address_hash`, `transfer_amount` - The bridge transfer, as for `op_deposits` / `op_withdrawals`.
    * `message_hash` - The v0 message hash the legacy messengers emit in their relay events.
    * `migrated_withdrawal_hash`, `migrated_message_hash`, `migrated_msg_data`, `migrated_gas_limit` - A withdrawal's
      identity after the Bedrock migration: the hash the v2 portal proves and finalizes, the hash the v2 messenger
      relays under, and the message a replay sends.
  """
  @primary_key false
  typed_schema "mantle_legacy_bridge_transfers" do
    field(:direction, Ecto.Enum, values: [:deposit, :withdrawal], primary_key: true)
    field(:nonce, :decimal, primary_key: true)
    field(:transaction_hash, Hash.Full)
    field(:block_number, :integer)
    field(:timestamp, :utc_datetime_usec)
    field(:transfer_type, Ecto.Enum, values: [:eth, :mnt, :erc20, :message])
    field(:transfer_from_address_hash, Hash.Address)
    field(:transfer_to_address_hash, Hash.Address)
    field(:l1_token_address_hash, Hash.Address)
    field(:l2_token_address_hash, Hash.Address)
    field(:transfer_amount, :decimal)
    field(:message_hash, Hash.Full)
    field(:migrated_withdrawal_hash, Hash.Full)
    field(:migrated_message_hash, Hash.Full)
    field(:migrated_msg_data, Data)
    field(:migrated_gas_limit, :decimal)

    timestamps()
  end

  @validated_constant "optimism_legacy_bridge_validated"

  @fields ~w(direction nonce transaction_hash block_number timestamp transfer_type transfer_from_address_hash
              transfer_to_address_hash l1_token_address_hash l2_token_address_hash transfer_amount message_hash
              migrated_withdrawal_hash migrated_message_hash migrated_msg_data migrated_gas_limit)a

  @doc """
    Returns the name of the constant that tells whether the backfilled rows are validated against the chain (`"true"`)
    or failed it (`"false"`). Only validated rows are served.
  """
  @spec validated_constant() :: String.t()
  def validated_constant, do: @validated_constant

  @doc """
    Inserts rows, replacing the stored row of the same direction and nonce, so that the backfill can repeat a range.
    Values are cast to the field types first, so hashes may be 0x strings and amounts integers; a value its field
    cannot take raises `Ecto.InvalidChangesetError` rather than being written as NULL. Returns the number of rows
    written.
  """
  @spec upsert_all([map()]) :: non_neg_integer()
  def upsert_all([]), do: 0

  def upsert_all(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn row ->
        %__MODULE__{}
        |> cast(row, @fields)
        |> apply_action!(:insert)
        |> Map.take(@fields)
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    {count, _} =
      Repo.insert_all(__MODULE__, entries,
        on_conflict: {:replace_all_except, [:direction, :nonce, :inserted_at]},
        conflict_target: [:direction, :nonce],
        timeout: :infinity
      )

    count
  end
end
