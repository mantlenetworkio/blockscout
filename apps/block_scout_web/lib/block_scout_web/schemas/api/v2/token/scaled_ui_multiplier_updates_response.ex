defmodule BlockScoutWeb.Schemas.API.V2.Token.ScaledUiMultiplierUpdatesResponse do
  @moduledoc false
  require OpenApiSpex

  alias BlockScoutWeb.Schemas.API.V2.Token.ScaledUiMultiplierUpdate
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%Schema{
    type: :object,
    properties: %{
      items: %Schema{type: :array, items: ScaledUiMultiplierUpdate},
      next_page_params: %Schema{
        type: :object,
        nullable: true,
        example: %{"block_number" => 23_484_141, "log_index" => 3}
      },
      timeline_status: %Schema{type: :string, enum: ["ok", "tainted"], nullable: true}
    },
    required: [:items, :next_page_params, :timeline_status],
    additionalProperties: false
  })
end
