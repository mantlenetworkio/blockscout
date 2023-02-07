defmodule Explorer.Chain.DaBatch do
  @moduledoc """
  A package of data that contains zero or more transactions, the hash of the previous block ("parent"), and optionally
  other data. Because each block (except for the initial "genesis block") points to the previous block, the data
  structure that they form is called a "blockchain".
  """

  use Explorer.Schema

  alias Explorer.Chain.{
    #Hash,
    Wei,
  }

  # alias Explorer.Chain.{Address, Gas, Hash, PendingBlockOperation, Transaction}
  # alias Explorer.Chain.Block.{Reward, SecondDegreeRelation}

  # @optional_attrs ~w(batch_index hash size pre_total_elements timestamp)a

  @required_attrs ~w(batch_index batch_size status start_block end_block da_hash store_id store_number da_fee)a

  @typedoc """
  How much work is required to find a hash with some number of leading 0s.  It is measured in hashes for PoW
  (Proof-of-Work) chains like Ethereum.  In PoA (Proof-of-Authority) chains, it does not apply as blocks are validated
  in a round-robin fashion, and so the value is always `Decimal.new(0)`.
  """
  @type difficulty :: Decimal.t()

  @typedoc """
  Number of the block in the chain.
  """
  @type block_number :: non_neg_integer()

  @type wei_per_gas :: Wei.t()

  @typedoc """
   * `consensus`
     * `true` - this is a block on the longest consensus agreed upon chain.
     * `false` - this is an uncle block from a fork.
   * `difficulty` - how hard the block was to mine.
   * `gas_limit` - If the total number of gas used by the computation spawned by the transaction, including the
     original message and any sub-messages that may be triggered, is less than or equal to the gas limit, then the
     transaction processes. If the total gas exceeds the gas limit, then all changes are reverted, except that the
     transaction is still valid and the fee can still be collected by the miner.
   * `gas_used` - The actual `t:gas/0` used to mine/validate the transactions in the block.
   * `hash` - the hash of the block.
   * `miner` - the hash of the `t:Explorer.Chain.Address.t/0` of the miner.  In Proof-of-Authority chains, this is the
     validator.
   * `nonce` - the hash of the generated proof-of-work.  Not used in Proof-of-Authority chains.
   * `number` - which block this is along the chain.
   * `parent_hash` - the hash of the parent block, which should have the previous `number`
   * `size` - The size of the block in bytes.
   * `timestamp` - When the block was collated
   * `total_difficulty` - the total `difficulty` of the chain until this block.
   * `transactions` - the `t:Explorer.Chain.Transaction.t/0` in this block.
  """
  @type t :: %__MODULE__{
          batch_index: integer(),
          batch_size: integer(),
          status: String.t(),
          start_block: integer(),
          end_block: integer(),
          da_hash: String.t(),
          store_id: integer(),
          store_number: integer(),
          da_fee: wei_per_gas,
          #timestamp: DateTime.t(),
        }

  @primary_key {:batch_index, :integer, autogenerate: false}
  schema "da_batches" do
    #field(:batch_index, :integer)
    field(:batch_size, :integer)
    field(:status, :string)
    field(:start_block, :integer)
    field(:end_block, :integer)
    field(:da_hash, :string)
    field(:store_id, :integer)
    field(:store_number, :integer)
    field(:da_fee, Wei)
    #timestamps()

  end

  def changeset(%__MODULE__{} = block, attrs) do
    block
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
  end

end
