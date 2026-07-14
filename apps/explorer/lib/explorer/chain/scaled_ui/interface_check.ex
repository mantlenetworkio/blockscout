defmodule Explorer.Chain.ScaledUi.InterfaceCheck do
  @moduledoc """
  Checks the ERC-8056 core and scheduled ERC-165 interfaces in one RPC batch.

  Contract-level failures are recorded as unsupported interfaces. Transport
  failures remain retryable and do not produce a cached result.
  """

  alias Explorer.Chain.ScaledUi.Events
  alias Explorer.Chain.Token

  @supports_interface_selector "01ffc9a7"
  @encoded_true "0x" <> String.pad_leading("1", 64, "0")

  @type result :: {:ok, %{core: boolean(), scheduled: boolean()}} | :rpc_error

  @doc "Checks both supported ERC-8056 interface identifiers."
  @spec run(Token.t(), EthereumJSONRPC.json_rpc_named_arguments()) :: result()
  def run(%Token{} = token, json_rpc_named_arguments) do
    interfaces = [
      {0, :core, Events.core_interface_id()},
      {1, :scheduled, Events.scheduled_interface_id()}
    ]

    requests = Enum.map(interfaces, &request(token, &1))

    case EthereumJSONRPC.json_rpc(requests, json_rpc_named_arguments) do
      {:ok, responses} when is_list(responses) ->
        responses_by_id = Map.new(responses, &{response_id(&1), &1})

        results =
          Map.new(interfaces, fn {id, name, _interface_id} ->
            {name, supported?(Map.get(responses_by_id, id))}
          end)

        {:ok, results}

      _error ->
        :rpc_error
    end
  end

  defp request(token, {id, _name, interface_id}) do
    EthereumJSONRPC.request(%{
      id: id,
      method: "eth_call",
      params: [
        %{
          data: encode_supports_interface(interface_id),
          to: to_string(token.contract_address_hash)
        },
        "latest"
      ]
    })
  end

  defp encode_supports_interface("0x" <> interface_id) do
    "0x" <> @supports_interface_selector <> interface_id <> String.duplicate("0", 56)
  end

  defp response_id(%{id: id}), do: id
  defp response_id(%{"id" => id}), do: id
  defp response_id(_response), do: nil

  defp supported?(%{result: @encoded_true}), do: true
  defp supported?(%{"result" => @encoded_true}), do: true
  defp supported?(_response), do: false
end
