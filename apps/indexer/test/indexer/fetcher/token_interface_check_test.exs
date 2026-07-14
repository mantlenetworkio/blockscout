defmodule Indexer.Fetcher.TokenInterfaceCheckTest do
  use EthereumJSONRPC.Case
  use Explorer.DataCase

  import Mox

  alias Explorer.Chain.ScaledUi.{InterfaceCheck, TokenState}
  alias Explorer.Chain.Token
  alias Explorer.Repo
  alias Indexer.Fetcher.Token, as: TokenFetcher

  setup :verify_on_exit!

  describe "run/2" do
    test "reports both supported interfaces", %{json_rpc_named_arguments: json_rpc_named_arguments} do
      token = insert(:token)
      expect_interface_responses([boolean_result(true), boolean_result(true)])

      assert InterfaceCheck.run(token, json_rpc_named_arguments) ==
               {:ok, %{core: true, scheduled: true}}
    end

    test "records false interface results", %{json_rpc_named_arguments: json_rpc_named_arguments} do
      token = insert(:token)
      expect_interface_responses([boolean_result(false), boolean_result(false)])

      assert InterfaceCheck.run(token, json_rpc_named_arguments) ==
               {:ok, %{core: false, scheduled: false}}
    end

    test "treats contract reverts as checked but unsupported", %{json_rpc_named_arguments: json_rpc_named_arguments} do
      token = insert(:token)
      expect_interface_responses([revert_result(), revert_result()])

      assert InterfaceCheck.run(token, json_rpc_named_arguments) ==
               {:ok, %{core: false, scheduled: false}}
    end

    test "leaves the check retryable after a transport timeout", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      token = insert(:token)

      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        assert_supports_interface_requests(requests)
        {:error, :timeout}
      end)

      assert InterfaceCheck.run(token, json_rpc_named_arguments) == :rpc_error
    end
  end

  describe "token catalog integration" do
    test "reconciles extensions and persists interface results for a capability token", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      token = uncataloged_token(extensions: ["ERC-7802"])
      insert_state(token, capability_block: 100)
      expect_interface_responses([boolean_result(true), boolean_result(false)])
      expect_metadata_response()

      assert TokenFetcher.run([token.contract_address_hash], json_rpc_named_arguments) == :ok

      reloaded_token = Repo.get!(Token, token.contract_address_hash)
      assert MapSet.new(reloaded_token.extensions) == MapSet.new(["ERC-7802", "ERC-8056"])

      state = Repo.get!(TokenState, token.contract_address_hash)
      assert state.iface_checked == true
      assert state.core_ext == true
      assert state.scheduled_ext == false
    end

    test "ignores a side-table placeholder without a capability boundary", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      token = uncataloged_token()
      insert_state(token, [])
      expect_metadata_response()

      assert TokenFetcher.run([token.contract_address_hash], json_rpc_named_arguments) == :ok

      assert Repo.get!(Token, token.contract_address_hash).extensions == nil
      assert Repo.get!(TokenState, token.contract_address_hash).iface_checked == false
    end

    test "does not repeat RPC after the interface result is cached", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      token = uncataloged_token()
      insert_state(token, capability_block: 100, iface_checked: true, core_ext: false, scheduled_ext: false)
      expect_metadata_response()

      assert TokenFetcher.run([token.contract_address_hash], json_rpc_named_arguments) == :ok

      assert Repo.get!(Token, token.contract_address_hash).extensions == ["ERC-8056"]
    end

    test "keeps a timed-out interface check retryable after extension reconciliation", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      token = uncataloged_token()
      insert_state(token, capability_block: 100)

      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        assert_supports_interface_requests(requests)
        {:error, :timeout}
      end)

      expect_metadata_response()

      assert TokenFetcher.run([token.contract_address_hash], json_rpc_named_arguments) == :ok

      reloaded_token = Repo.get!(Token, token.contract_address_hash)
      assert reloaded_token.extensions == ["ERC-8056"]
      assert reloaded_token.cataloged == false
      assert Repo.get!(TokenState, token.contract_address_hash).iface_checked == false
    end
  end

  defp expect_interface_responses(results) do
    expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
      assert_supports_interface_requests(requests)

      responses =
        requests
        |> Enum.zip(results)
        |> Enum.map(fn {%{id: id}, result} -> Map.put(result, :id, id) end)

      {:ok, responses}
    end)
  end

  defp expect_metadata_response do
    expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
      {:ok,
       Enum.map(requests, fn
         %{id: id, method: "eth_call", params: [%{data: "0x313ce567"}, "latest"]} ->
           %{id: id, result: uint_result(18)}

         %{id: id, method: "eth_call", params: [%{data: "0x06fdde03"}, "latest"]} ->
           %{
             id: id,
             result:
               "0x0000000000000000000000000000000000000000000000000000000000000020" <>
                 "0000000000000000000000000000000000000000000000000000000000000006" <>
                 "42616e636f720000000000000000000000000000000000000000000000000000"
           }

         %{id: id, method: "eth_call", params: [%{data: "0x95d89b41"}, "latest"]} ->
           %{
             id: id,
             result:
               "0x0000000000000000000000000000000000000000000000000000000000000020" <>
                 "0000000000000000000000000000000000000000000000000000000000000003" <>
                 "424e540000000000000000000000000000000000000000000000000000000000"
           }

         %{id: id, method: "eth_call", params: [%{data: "0x18160ddd"}, "latest"]} ->
           %{id: id, result: uint_result(1_000_000)}
       end)}
    end)
  end

  defp assert_supports_interface_requests(requests) do
    assert length(requests) == 2

    assert Enum.all?(requests, fn request ->
             request.method == "eth_call" and
               request.params |> hd() |> Map.fetch!(:data) |> String.starts_with?("0x01ffc9a7")
           end)
  end

  defp boolean_result(value) do
    encoded = if value, do: String.pad_leading("1", 64, "0"), else: String.duplicate("0", 64)
    %{result: "0x" <> encoded}
  end

  defp revert_result do
    %{error: %{code: 3, data: "0x", message: "execution reverted"}}
  end

  defp uncataloged_token(options \\ []) do
    insert(
      :token,
      Keyword.merge(
        [cataloged: false, decimals: nil, name: nil, symbol: nil, total_supply: nil],
        options
      )
    )
  end

  defp insert_state(token, options) do
    params = Map.new([{:token_contract_address_hash, token.contract_address_hash} | options])

    %TokenState{}
    |> TokenState.changeset(params)
    |> Repo.insert!()
  end

  defp uint_result(value) do
    "0x" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
  end
end
