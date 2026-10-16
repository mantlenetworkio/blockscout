defmodule BlockScoutWeb.Schemas.API.V2.Optimism.Deposit do
  @moduledoc """
  This module defines the schema for the Optimism Deposit struct.
  """
  require OpenApiSpex

  alias BlockScoutWeb.Schemas.API.V2.General
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OptimismDeposit",
    description: "Optimism Deposit struct.",
    type: :object,
    properties: %{
      l1_block_number: %Schema{type: :integer},
      l1_block_timestamp: General.Timestamp,
      l1_transaction_hash: General.FullHash,
      l1_transaction_origin: General.AddressHash,
      l2_transaction_gas_limit: General.IntegerString,
      l2_transaction_hash: General.FullHash,
      message_hash: General.FullHashNullable,
      msg_data: General.HexStringNullable,
      msg_target_address_hash: General.AddressHashNullable,
      relay_status: %Schema{type: :string, enum: ["Relayed", "Relay failed"], nullable: true},
      relay_transaction_hash: General.FullHashNullable
    },
    required: [
      :l1_block_number,
      :l1_block_timestamp,
      :l1_transaction_hash,
      :l1_transaction_origin,
      :l2_transaction_gas_limit,
      :l2_transaction_hash,
      :message_hash,
      :msg_data,
      :msg_target_address_hash,
      :relay_status,
      :relay_transaction_hash
    ],
    additionalProperties: false
  })
end
