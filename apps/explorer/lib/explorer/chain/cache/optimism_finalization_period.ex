defmodule Explorer.Chain.Cache.OptimismFinalizationPeriod do
  @moduledoc """
  Caches Optimism Finalization period.

  The cached value expires after `global_ttl` and is then re-fetched from the
  L2OutputOracle contract, so on-chain changes of FINALIZATION_PERIOD_SECONDS
  are picked up without a node restart.
  """

  require Logger

  use Explorer.Chain.MapCache,
    name: :optimism_finalization_period,
    key: :period,
    ttl_check_interval: :timer.minutes(1),
    global_ttl: :timer.minutes(5)

  import EthereumJSONRPC, only: [json_rpc: 2, quantity_to_integer: 1]

  alias EthereumJSONRPC.Contract
  alias Indexer.Fetcher.Optimism
  alias Indexer.Fetcher.Optimism.OutputRoot

  defp handle_fallback(:period) do
    optimism_l1_rpc = Application.get_all_env(:indexer)[Optimism][:optimism_l1_rpc]
    output_oracle = Application.get_all_env(:indexer)[OutputRoot][:output_oracle]

    # call FINALIZATION_PERIOD_SECONDS() public getter of L2OutputOracle contract on L1
    request = Contract.eth_call_request("0xf4daa291", output_oracle, 0, nil, nil)

    case json_rpc(request, Indexer.Helper.json_rpc_named_arguments(optimism_l1_rpc)) do
      {:ok, value} ->
        {:update, quantity_to_integer(value)}

      {:error, reason} ->
        Logger.debug([
          "Couldn't fetch Optimism finalization period, reason: #{inspect(reason)}"
        ])

        {:return, nil}
    end
  end

  defp handle_fallback(_key), do: {:return, nil}
end
