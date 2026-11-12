# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.HelperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Mox

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

  describe "get_blocks_by_events/4" do
    setup :verify_on_exit!

    setup do
      %{json_rpc_named_arguments: [transport: EthereumJSONRPC.Mox, transport_options: []]}
    end

    # geth answers `response too large` to the requests left once the responses of a batch exceed its
    # `--rpc.batch-response-max-size`, and keeps the responses before
    test "requests again the blocks a batch answers with an error", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        assert length(requests) == 3

        {:ok,
         Enum.map(requests, fn
           %{params: ["0x3", true]} = request -> error_response(request)
           request -> block_response(request)
         end)}
      end)

      expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{params: ["0x3", true]} = request], _options ->
        {:ok, [block_response(request)]}
      end)

      assert block_numbers(Helper.get_blocks_by_events(events(1..3), json_rpc_named_arguments, 1, true)) ==
               ["0x1", "0x2", "0x3"]
    end

    # A rate limit that fails the rest of a batch, then the resend as a whole (one error without an id), then a lagging
    # node behind a gateway that answers `null`
    test "keeps the blocks fetched and sends the others again, after a pause in smaller batches when none is fetched",
         %{
           json_rpc_named_arguments: json_rpc_named_arguments
         } do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        assert length(requests) == 4

        {:ok,
         Enum.map(requests, fn
           %{params: [number, true]} = request when number in ["0x1", "0x2"] -> block_response(request)
           request -> error_response(request)
         end)}
      end)

      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        assert requests |> Enum.map(&hd(&1.params)) |> Enum.sort() == ["0x3", "0x4"]
        {:ok, [%{jsonrpc: "2.0", id: nil, error: %{code: -32005, message: "rate limit exceeded"}}]}
      end)

      expect(EthereumJSONRPC.Mox, :json_rpc, 2, fn
        [%{params: ["0x3", true]} = request], _options -> {:ok, [block_response(request)]}
        [%{id: id, params: ["0x4", true]}], _options -> {:ok, [%{jsonrpc: "2.0", id: id, result: nil}]}
      end)

      expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{params: ["0x4", true]} = request], _options ->
        {:ok, [block_response(request)]}
      end)

      {microseconds, _} =
        :timer.tc(fn ->
          capture_log(fn ->
            assert block_numbers(Helper.get_blocks_by_events(events(1..4), json_rpc_named_arguments, 2, true)) ==
                     ["0x1", "0x2", "0x3", "0x4"]
          end)
        end)

      # the pause of `Helper.pause_before_retry(0)` before the requests are sent one by one
      assert microseconds >= 3_000_000
    end

    test "leaves out the blocks it still cannot fetch once the retries are used up", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _options ->
        {:ok,
         Enum.map(requests, fn
           %{params: ["0x2", true]} = request -> error_response(request)
           request -> block_response(request)
         end)}
      end)

      expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{params: ["0x2", true]} = request], _options ->
        {:ok, [error_response(request)]}
      end)

      log =
        capture_log(fn ->
          assert block_numbers(Helper.get_blocks_by_events(events(1..2), json_rpc_named_arguments, 1, true)) == ["0x1"]
        end)

      assert log =~ "Cannot fetch blocks with batch request"
    end

    # a response for an id the batch did not request must not count as progress, or the batch would be sent again at
    # once without end
    test "leaves out a block it did not request", %{json_rpc_named_arguments: json_rpc_named_arguments} do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id}] = requests, _options ->
        {:ok, Enum.map(requests, &error_response/1) ++ [block_response(%{id: id + 1, params: ["0x2", true]})]}
      end)

      capture_log(fn ->
        assert Helper.get_blocks_by_events(events(1..1), json_rpc_named_arguments, 1, true) == []
      end)
    end
  end

  defp events(block_numbers), do: Enum.map(block_numbers, &%{"blockNumber" => "0x#{Integer.to_string(&1, 16)}"})

  defp block_response(%{id: id, params: [number, _]}),
    do: %{jsonrpc: "2.0", id: id, result: %{"number" => number, "timestamp" => "0x0"}}

  defp error_response(%{id: id}), do: %{jsonrpc: "2.0", id: id, error: %{code: -32003, message: "response too large"}}

  defp block_numbers(blocks), do: blocks |> Enum.map(& &1["number"]) |> Enum.sort()
end
