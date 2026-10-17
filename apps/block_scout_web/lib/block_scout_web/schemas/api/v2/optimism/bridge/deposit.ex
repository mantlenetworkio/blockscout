defmodule BlockScoutWeb.Schemas.API.V2.Optimism.Bridge.Deposit do
  @moduledoc """
  This module defines the schema of a deposit in the bridge history of an address.
  """
  require OpenApiSpex

  alias BlockScoutWeb.Schemas.API.V2.General
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OptimismBridgeDeposit",
    description:
      "A deposit the address sent or received through the bridge. `msg_data` and `msg_target_address_hash` are set " <>
        "only when the L2 relay failed: they are what a replay needs. A v1 (pre-Bedrock) deposit (`is_legacy`) has " <>
        "the transaction that relayed it as `l2_transaction_hash`, so none until it is relayed, and no replay payload.",
    type: :object,
    properties: %{
      l1_transaction_hash: General.FullHash,
      l1_block_number: %Schema{type: :integer},
      l1_block_timestamp: General.TimestampNullable,
      l2_transaction_hash: General.FullHashNullable,
      status: %Schema{type: :string, enum: ["Pending", "Failed", "Relayed", "Relay failed"], nullable: false},
      transfer_type: %Schema{type: :string, enum: ["eth", "mnt", "erc20", "message"], nullable: false},
      from_address_hash: General.AddressHashNullable,
      to_address_hash: General.AddressHashNullable,
      l1_token_address_hash: General.AddressHashNullable,
      l2_token_address_hash: General.AddressHashNullable,
      amount: General.IntegerStringNullable,
      mnt_value: General.IntegerStringNullable,
      eth_value: General.IntegerStringNullable,
      message_hash: General.FullHashNullable,
      relay_transaction_hash: General.FullHashNullable,
      msg_data: General.HexStringNullable,
      msg_target_address_hash: General.AddressHashNullable,
      is_legacy: %Schema{type: :boolean, nullable: false}
    },
    required: [
      :l1_transaction_hash,
      :l1_block_number,
      :l1_block_timestamp,
      :l2_transaction_hash,
      :status,
      :transfer_type,
      :from_address_hash,
      :to_address_hash,
      :l1_token_address_hash,
      :l2_token_address_hash,
      :amount,
      :mnt_value,
      :eth_value,
      :message_hash,
      :relay_transaction_hash,
      :msg_data,
      :msg_target_address_hash,
      :is_legacy
    ],
    additionalProperties: false
  })
end
