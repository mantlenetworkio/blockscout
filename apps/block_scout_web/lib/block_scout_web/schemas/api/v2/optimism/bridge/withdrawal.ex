defmodule BlockScoutWeb.Schemas.API.V2.Optimism.Bridge.Withdrawal do
  @moduledoc """
  This module defines the schema of a withdrawal in the bridge history of an address.
  """
  require OpenApiSpex

  alias BlockScoutWeb.Schemas.API.V2.General
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OptimismBridgeWithdrawal",
    description:
      "A withdrawal the address sent or received through the bridge. `l1_transaction_hash` is the finalizing " <>
        "transaction. `msg_data`, `msg_target_address_hash` and `msg_gas_limit` are set only when the L1 relay " <>
        "failed: they are what a replay needs. A v1 (pre-Bedrock) withdrawal (`is_legacy`) relayed in the v1 era has " <>
        "that relay as its finalizing transaction; any other has the `message_hash` and replay payload the Bedrock " <>
        "migration gave it.",
    type: :object,
    properties: %{
      l2_transaction_hash: General.FullHash,
      l2_block_number: %Schema{type: :integer},
      l2_timestamp: General.TimestampNullable,
      msg_nonce_raw: General.IntegerString,
      status: %Schema{
        type: :string,
        enum: [
          "Waiting for state root",
          "Ready to prove",
          "Waiting a game to resolve",
          "In challenge period",
          "Ready for relay",
          "Proven",
          "Relayed",
          "Relay failed"
        ],
        nullable: false
      },
      challenge_period_end: General.TimestampNullable,
      prove_transaction_hash: General.FullHashNullable,
      l1_transaction_hash: General.FullHashNullable,
      relay_transaction_hash: General.FullHashNullable,
      transfer_type: %Schema{type: :string, enum: ["eth", "mnt", "erc20", "message"], nullable: false},
      from_address_hash: General.AddressHashNullable,
      to_address_hash: General.AddressHashNullable,
      l1_token_address_hash: General.AddressHashNullable,
      l2_token_address_hash: General.AddressHashNullable,
      amount: General.IntegerStringNullable,
      mnt_value: General.IntegerStringNullable,
      eth_value: General.IntegerStringNullable,
      message_hash: General.FullHashNullable,
      msg_data: General.HexStringNullable,
      msg_target_address_hash: General.AddressHashNullable,
      msg_gas_limit: General.IntegerStringNullable,
      is_legacy: %Schema{type: :boolean, nullable: false}
    },
    required: [
      :l2_transaction_hash,
      :l2_block_number,
      :l2_timestamp,
      :msg_nonce_raw,
      :status,
      :challenge_period_end,
      :prove_transaction_hash,
      :l1_transaction_hash,
      :relay_transaction_hash,
      :transfer_type,
      :from_address_hash,
      :to_address_hash,
      :l1_token_address_hash,
      :l2_token_address_hash,
      :amount,
      :mnt_value,
      :eth_value,
      :message_hash,
      :msg_data,
      :msg_target_address_hash,
      :msg_gas_limit,
      :is_legacy
    ],
    additionalProperties: false
  })
end
