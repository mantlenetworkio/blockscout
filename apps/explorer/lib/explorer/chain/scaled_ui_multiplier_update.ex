defmodule Explorer.Chain.ScaledUiMultiplierUpdate do
  @moduledoc """
  A single entry in an ERC-8056 token's UI multiplier schedule timeline.

  Each row is one `UIMultiplierUpdated` or `UIMultiplierChangeOverwritten` event.
  `effective_at` / `block_timestamp` are stored as `numeric` Unix seconds because
  the on-chain `effectiveAt` is an unbounded `uint256` (a `timestamptz` would
  overflow and fail the whole import batch).

  The FK targets `addresses(hash)`, not `tokens`, because the indexer may see an
  event before the token is cataloged. This is an address-owned event stream;
  token capability is marked separately on `tokens.extensions`.
  """

  use Explorer.Schema

  alias Explorer.Chain.{Address, Block, Hash, Transaction}

  @event_types ~w(updated overwritten)

  @base_required_attrs ~w(token_contract_address_hash transaction_hash block_hash log_index block_number block_timestamp event_type)a
  @optional_attrs ~w(old_multiplier new_multiplier effective_at overwritten_multiplier overwritten_effective_at)a

  @primary_key false
  typed_schema "scaled_ui_multiplier_updates" do
    field(:block_number, :integer)
    field(:log_index, :integer, primary_key: true, null: false)
    field(:block_timestamp, :decimal, null: false)
    field(:event_type, :string, null: false)
    field(:old_multiplier, :decimal)
    field(:new_multiplier, :decimal)
    field(:effective_at, :decimal)
    field(:overwritten_multiplier, :decimal)
    field(:overwritten_effective_at, :decimal)

    belongs_to(:token_contract_address, Address,
      foreign_key: :token_contract_address_hash,
      primary_key: true,
      references: :hash,
      type: Hash.Address,
      null: false
    )

    belongs_to(:block, Block,
      foreign_key: :block_hash,
      primary_key: true,
      references: :hash,
      type: Hash.Full,
      null: false
    )

    belongs_to(:transaction, Transaction,
      foreign_key: :transaction_hash,
      references: :hash,
      type: Hash.Full,
      null: false
    )

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = struct, params \\ %{}) do
    struct
    |> cast(params, @base_required_attrs ++ @optional_attrs)
    |> validate_required(@base_required_attrs)
    |> validate_inclusion(:event_type, @event_types)
    |> validate_event_shape()
    |> foreign_key_constraint(:token_contract_address_hash)
    |> foreign_key_constraint(:block_hash)
    |> foreign_key_constraint(:transaction_hash)
  end

  # Conditional required-fields by event_type (mirrors the DB CHECK constraints
  # so non-bulk callers get an Ecto error instead of a Postgrex.Error).
  defp validate_event_shape(changeset) do
    case get_field(changeset, :event_type) do
      "updated" ->
        validate_required(changeset, [:old_multiplier, :new_multiplier, :effective_at])

      "overwritten" ->
        validate_required(changeset, [
          :new_multiplier,
          :effective_at,
          :overwritten_multiplier,
          :overwritten_effective_at
        ])

      _ ->
        changeset
    end
  end
end
