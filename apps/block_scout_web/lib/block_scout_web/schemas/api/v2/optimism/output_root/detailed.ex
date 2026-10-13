defmodule BlockScoutWeb.Schemas.API.V2.Optimism.OutputRoot.Detailed do
  @moduledoc """
  This module defines the schema for the response from /api/v2/optimism/output-roots/:index.
  """
  require OpenApiSpex

  alias BlockScoutWeb.Schemas.API.V2.General
  alias BlockScoutWeb.Schemas.API.V2.Optimism.OutputRoot
  alias BlockScoutWeb.Schemas.Helper
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    OutputRoot.schema()
    |> Helper.extend_schema(
      title: "OptimismOutputRootDetailed",
      description: "Optimism output root with the L2 block range it commits to and the L1 finality of its proposal.",
      properties: %{
        l2_start_block_number: %Schema{
          type: :integer,
          nullable: true,
          description: "First L2 block of the committed range; null when the previous root is not indexed."
        },
        l2_end_block_number: %Schema{
          type: :integer,
          nullable: false,
          description: "Last L2 block of the committed range."
        },
        blocks_count: %Schema{
          type: :integer,
          nullable: true,
          description: "Number of L2 blocks in the range; null when the range is unknown."
        },
        transactions_count: %Schema{
          type: :integer,
          nullable: true,
          description: "Number of L2 transactions in the range; null when the range is unknown."
        },
        l1_finality: %Schema{
          type: :string,
          enum: ["unsafe", "safe", "finalized"],
          nullable: true,
          description: "L1 finality of the proposal transaction; null while the L1 heads are unknown."
        },
        challenge_period_end: General.TimestampNullable
      },
      required: [
        :l2_start_block_number,
        :l2_end_block_number,
        :blocks_count,
        :transactions_count,
        :l1_finality,
        :challenge_period_end
      ]
    )
  )
end
