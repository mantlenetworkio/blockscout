defmodule BlockScoutWeb.Schemas.API.V2.Token.ScaledUiMultiplierUpdate do
  @moduledoc false
  require OpenApiSpex

  alias BlockScoutWeb.Schemas.API.V2.General
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%Schema{
    type: :object,
    properties: %{
      block_hash: General.FullHash,
      block_number: %Schema{type: :integer, minimum: 0},
      block_timestamp: General.Timestamp,
      effective_at: General.IntegerString,
      event_type: %Schema{type: :string, enum: ["updated", "overwritten"]},
      log_index: %Schema{type: :integer, minimum: 0},
      new_multiplier: General.IntegerString,
      old_multiplier: General.IntegerStringNullable,
      overwritten_effective_at: General.IntegerStringNullable,
      overwritten_multiplier: General.IntegerStringNullable,
      status: %Schema{type: :string, enum: ["active", "pending", "superseded"]},
      transaction_hash: General.FullHash
    },
    required: [
      :block_hash,
      :block_number,
      :block_timestamp,
      :effective_at,
      :event_type,
      :log_index,
      :new_multiplier,
      :old_multiplier,
      :overwritten_effective_at,
      :overwritten_multiplier,
      :status,
      :transaction_hash
    ],
    additionalProperties: false
  })
end
