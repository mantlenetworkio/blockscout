# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.HelperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Indexer.Helper

  describe "l1_json_rpc_named_arguments/1" do
    test "builds expected JSON-RPC named arguments from RPC URL" do
      rpc_url = "https://rpc.example"
      timeout = :timer.minutes(10)

      assert Helper.l1_json_rpc_named_arguments(rpc_url) ==
               [
                 transport: EthereumJSONRPC.HTTP,
                 transport_options: [
                   http: EthereumJSONRPC.HTTP.Tesla,
                   urls: [rpc_url],
                   http_options: [
                     recv_timeout: timeout,
                     timeout: timeout,
                     pool: :ethereum_jsonrpc,
                     layer: :l1
                   ]
                 ]
               ]
    end

    test "handles nil RPC URL" do
      assert_raise ArgumentError, "RPC URL must be a non-empty string", fn ->
        Helper.l1_json_rpc_named_arguments(nil)
      end
    end

    test "handles empty string RPC URL" do
      assert_raise ArgumentError, "RPC URL must be a non-empty string", fn ->
        Helper.l1_json_rpc_named_arguments("")
      end
    end

    test "normalizes trailing slash in RPC URL" do
      timeout = :timer.minutes(10)

      assert Helper.l1_json_rpc_named_arguments("https://rpc.example/") ==
               [
                 transport: EthereumJSONRPC.HTTP,
                 transport_options: [
                   http: EthereumJSONRPC.HTTP.Tesla,
                   urls: ["https://rpc.example"],
                   http_options: [
                     recv_timeout: timeout,
                     timeout: timeout,
                     pool: :ethereum_jsonrpc,
                     layer: :l1
                   ]
                 ]
               ]
    end
  end

  describe "http_get_request/5" do
    setup do
      %{bypass: Bypass.open(), calls: :counters.new(1, [])}
    end

    test "gives up after max_attempts attempts", %{bypass: bypass, calls: calls} do
      Bypass.expect(bypass, fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.resp(conn, 503, "")
      end)

      capture_log(fn ->
        assert {:error, _} = Helper.http_get_request("http://localhost:#{bypass.port}/", :json, 0, [404], 2)
      end)

      assert :counters.get(calls, 1) == 2
    end

    test "makes one attempt when the status is one not to retry", %{bypass: bypass, calls: calls} do
      Bypass.expect(bypass, fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.resp(conn, 400, "")
      end)

      assert {:error, {:http_status, 400, _}} =
               Helper.http_get_request("http://localhost:#{bypass.port}/", :json, 0, [400, 404])

      assert :counters.get(calls, 1) == 1
    end
  end
end
