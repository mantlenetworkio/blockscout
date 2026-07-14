defmodule Explorer.Chain.Import.Runner.ScaledUiTokenStates do
  @moduledoc """
  Rebuilds ERC-8056 token capability boundaries and multiplier summaries.
  """

  alias Ecto.Multi
  alias Explorer.Chain.{Hash, Import}
  alias Explorer.Chain.ScaledUi.TokenState
  alias Explorer.Prometheus.Instrumenter

  @behaviour Import.Runner

  @timeout 60_000

  @type imported :: [Hash.Address.t()]

  @impl Import.Runner
  def ecto_schema_module, do: TokenState

  @impl Import.Runner
  def option_key, do: :scaled_ui_token_states

  @impl Import.Runner
  def imported_table_row do
    %{
      value_type: "[#{Hash.Address}.t()]",
      value_description: "List of token contract address hashes whose state was rebuilt"
    }
  end

  @impl Import.Runner
  def run(multi, changes_list, options) do
    timeout = options |> Map.get(option_key(), %{}) |> Map.get(:timeout, @timeout)

    Multi.run(multi, :scaled_ui_token_states, fn repo, _changes ->
      Instrumenter.block_import_stage_runner(
        fn -> TokenState.rebuild(repo, changes_list, timeout: timeout) end,
        :token_referencing,
        :scaled_ui_token_states,
        :rebuild
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout
end
