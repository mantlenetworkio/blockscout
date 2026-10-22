defmodule Indexer.Fetcher.Optimism.DepositTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import ExUnit.CaptureLog, only: [capture_log: 1]
    import Explorer.OptimismBridgeFixtures
    import Mox

    alias Explorer.Chain.Cache.LatestL1BlockNumber
    alias Explorer.Chain.Hash
    alias Explorer.Chain.Optimism.BridgeMessage
    alias Explorer.Chain.Optimism.Deposit, as: DepositSchema
    alias Explorer.Repo
    alias Indexer.Fetcher.Optimism
    alias Indexer.Fetcher.Optimism.Deposit
    alias Indexer.RollupReorgMonitorQueue

    @op_sepolia_path Path.join(__DIR__, "../../../support/fixture/optimism/op_sepolia_deposits.json")
    @external_resource @op_sepolia_path
    @op_sepolia_deposits @op_sepolia_path |> File.read!() |> Jason.decode!() |> Map.fetch!("deposits")

    @portal "0xb3db4bd5bc225930ed674494f9a4f6a11b8efbc8"

    # opaqueData of the synthetic contract creations (see their tests)
    @mantle_v0_creation_data "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000006e000000000000000000000000000000000000000000000000000000000000123400000000000000000000000000000000000000000000000000000000000056780000000000000000000000000000000000000000000000000000000000009abc0000000000030d40016080604052000000000000000000000000000000000000"
    @standard_creation_data "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004e000000000000000000000000000000000000000000000000000000000000111100000000000000000000000000000000000000000000000000000000000022220000000000030d40016080604052000000000000000000000000000000000000"

    setup {Mox, :verify_on_exit!}

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      %{json_rpc_named_arguments: Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)}
    end

    describe "event_to_deposit/5" do
      # creation: a contract creation, whose L2 transaction has no `to`. v0_eth and v0_no_calldata: version 0 events,
      # which the Mantle Sepolia portal emitted until July 2024 (they have no ethTxValue). The second one carries no
      # calldata, so its opaqueData is shorter than any version 1 opaqueData.
      for name <- [:eth, :mnt, :erc20, :message, :creation, :v0_eth, :v0_no_calldata] do
        test "derives the L2 transaction of the Sepolia #{name} deposit and decodes its transfer" do
          configure_bridges()
          fixture = deposit(unquote(name))
          expected = expected_transfer(fixture)

          deposit = Deposit.event_to_deposit(fixture["l1_event"], %{}, %{}, 126, BridgeMessage.bridges())

          assert deposit.l2_transaction_hash == fixture["l2_transaction_hash"]
          assert Map.take(deposit, Map.keys(expected)) == expected
        end
      end

      test "leaves the transfer out when decoding is not configured" do
        configure_bridges()
        fixture = deposit(:eth)

        deposit = Deposit.event_to_deposit(fixture["l1_event"], %{}, %{}, 126, nil)

        assert deposit.l2_transaction_hash == fixture["l2_transaction_hash"]
        refute Map.has_key?(deposit, :transfer_type)
      end

      test "skips an event of an unknown version" do
        configure_bridges()
        event = with_version(deposit(:eth)["l1_event"], 2)

        log =
          capture_log(fn -> assert Deposit.event_to_deposit(event, %{}, %{}, 126, BridgeMessage.bridges()) == nil end)

        assert log =~ event["transactionHash"]
      end

      test "skips an event whose opaqueData is too short for its version" do
        configure_bridges()
        event = with_version(deposit(:v0_no_calldata)["l1_event"], 1)

        log =
          capture_log(fn -> assert Deposit.event_to_deposit(event, %{}, %{}, 126, BridgeMessage.bridges()) == nil end)

        assert log =~ event["transactionHash"]
      end

      # Mantle Sepolia has no version 0 contract creation. This one is the v0_no_calldata event carrying a creation's
      # opaqueData (mint 0x1234 MNT, transfer 0x5678 MNT, mint 0x9abc ETH, init code 0x6080604052) with `to` cleared;
      # its hash was derived with viem.
      test "derives the L2 transaction of a Mantle version 0 contract creation" do
        configure_bridges()
        %{"topics" => [signature, from, _to, version]} = event = deposit(:v0_no_calldata)["l1_event"]

        event = %{event | "topics" => [signature, from, hash(0), version], "data" => @mantle_v0_creation_data}

        assert %{
                 l2_transaction_hash: "0x4dc469d4b13fef7150bee0d683a1c4aa5bd5d78f9e51f890f4f51b6b3570cbb4",
                 transfer_type: :message,
                 transfer_from_address_hash: "0x25b903c548436f3b563a5f6396071df82df560b5",
                 transfer_to_address_hash: nil,
                 mnt_value: 0x5678,
                 eth_value: 0
               } = Deposit.event_to_deposit(event, %{}, %{}, 126, BridgeMessage.bridges())
      end
    end

    describe "event_to_deposit/5 outside Mantle mode" do
      setup do
        previous = Application.get_env(:indexer, Optimism)
        Application.put_env(:indexer, Optimism, Keyword.put(previous || [], :mantle_mode, false))
        on_exit(fn -> Application.put_env(:indexer, Optimism, previous) end)
      end

      for name <- ["normal", "eth", "creation"] do
        test "derives the L2 transaction of the OP Sepolia #{name} deposit" do
          fixture = @op_sepolia_deposits[unquote(name)]

          deposit = Deposit.event_to_deposit(fixture["l1_event"], %{}, %{}, 126, nil)

          assert deposit.l2_transaction_hash == fixture["l2_transaction_hash"]
        end
      end

      # The OP Sepolia creation event carrying a creation's opaqueData with distinct values (mint 0x1111, value 0x2222,
      # init code 0x6080604052); its hash was derived with viem.
      test "derives the L2 transaction of a contract creation that mints and transfers" do
        %{"topics" => [signature, from, _to, version]} = event = @op_sepolia_deposits["creation"]["l1_event"]

        event = %{event | "topics" => [signature, from, hash(0), version], "data" => @standard_creation_data}

        assert %{l2_transaction_hash: "0x62895332d72b8292f8d8276d9ee7d199b38c3695b00c1845e2c617026e869fe5"} =
                 Deposit.event_to_deposit(event, %{}, %{}, 126, nil)
      end

      # the OP Stack portal emits version 0 events only
      test "skips a Mantle version 1 event" do
        event = deposit(:creation)["l1_event"]

        log = capture_log(fn -> assert Deposit.event_to_deposit(event, %{}, %{}, 126, nil) == nil end)

        assert log =~ event["transactionHash"]
      end
    end

    describe "handle_info(:continue, state)" do
      setup do
        configure_bridges()
        LatestL1BlockNumber.set_block_number(11_014_900)
        on_exit(fn -> ConCache.delete(LatestL1BlockNumber.cache_name(), :block_number) end)
      end

      # An event the derivation cannot parse used to raise, so the fetcher fetched the same chunk again on every
      # restart and never got past it
      test "imports the deposits of a chunk and skips the events it cannot parse", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        index_chunk_with_unparsable_event(json_rpc_named_arguments)

        assert [l2_transaction_hash] = Repo.all(from(d in DepositSchema, select: d.l2_transaction_hash))
        assert to_string(l2_transaction_hash) == deposit(:creation)["l2_transaction_hash"]
      end

      # While a deployment rolls over, a fetcher of the previous version keeps importing after this one removed the
      # deposits it derived. Its rows of the blocks of a chunk give way to the chunk's deposits; other rows stay.
      test "replaces the rows of the chunk's blocks that its deposits do not include", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        # the hash the previous version derived for the creation deposit
        {:ok, previous_hash} = Hash.Full.cast("0x8a1dcfe7ce0e40e130eed4809247d4ef81bd1ed888ece3f13f26501ee7156d24")
        insert(:op_deposit, l1_block_number: 11_014_804, l2_transaction_hash: previous_hash, l2_transaction: nil)
        %{l2_transaction_hash: before_chunk} = insert(:op_deposit, l1_block_number: 11_014_799)
        %{l2_transaction_hash: after_chunk} = insert(:op_deposit, l1_block_number: 11_014_811)

        index_chunk_with_unparsable_event(json_rpc_named_arguments)

        assert [{11_014_799, ^before_chunk}, {11_014_804, creation}, {11_014_811, ^after_chunk}] =
                 Repo.all(
                   from(d in DepositSchema,
                     select: {d.l1_block_number, d.l2_transaction_hash},
                     order_by: d.l1_block_number
                   )
                 )

        assert to_string(creation) == deposit(:creation)["l2_transaction_hash"]
      end

      test "resumes from the last block of the chunk after a restart", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        index_chunk_with_unparsable_event(json_rpc_named_arguments)

        # the checkpoint goes out in upper-case hex (`Optimism.get_last_block_hash/1`)
        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getBlockByHash", params: [block_hash, false]},
                                                  _options ->
          assert String.downcase(block_hash) == hash(11_014_810)
          {:ok, block_response(11_014_810)}
        end)

        assert {11_014_810, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)
        assert 1 == Repo.aggregate(DepositSchema, :count)
      end
    end

    describe "get_last_l1_item/1" do
      setup do
        LatestL1BlockNumber.set_block_number(300)
        on_exit(fn -> ConCache.delete(LatestL1BlockNumber.cache_name(), :block_number) end)
      end

      # The deposits indexed before creation deposits and Mantle v0 events were derived the way op-node derives them
      # are checkpointed under the previous counter name only
      test "derives every deposit again when it has no checkpoint of its own", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        insert(:op_deposit, l1_block_number: 110)
        insert(:op_deposit, l1_block_number: 150)
        Optimism.set_last_block_hash(hash(150), "optimism_deposits_fetcher_last_l1_block_hash")

        stub(EthereumJSONRPC.Mox, :json_rpc, fn
          %{method: "eth_getBlockByHash"}, _options -> {:ok, block_response(150)}
          %{method: "eth_getTransactionByHash", params: [hash]}, _options -> {:ok, %{"hash" => to_string(hash)}}
        end)

        log = capture_log(fn -> assert {0, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments) end)

        assert [] == Repo.all(DepositSchema)
        assert log =~ "2 rows"
      end

      # An L1 reorg resets the checkpoint to the empty hash, and the fetcher resumes from the last deposit left. Here the
      # fetcher handles blocks 200..299 when it learns of a reorg from block 120.
      test "keeps the deposits once an L1 reorg has reset its checkpoint", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        kept = insert(:op_deposit, l1_block_number: 110)
        insert(:op_deposit, l1_block_number: 150)
        RollupReorgMonitorQueue.push(120, Deposit)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getLogs"}, _options -> {:ok, []} end)

        capture_log(fn ->
          assert {:noreply, %{start_block: 120}} =
                   Deposit.handle_info(:continue, state(json_rpc_named_arguments, 200, 299))
        end)

        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getTransactionByHash", params: [hash]}, _options ->
          {:ok, %{"hash" => to_string(hash)}}
        end)

        assert {110, last_transaction_hash, %{}} = Deposit.get_last_l1_item(json_rpc_named_arguments)
        assert last_transaction_hash == kept.l1_transaction_hash
        assert [110] == Repo.all(from(d in DepositSchema, select: d.l1_block_number))
      end
    end

    # Runs the fetcher over L1 blocks 11,014,800..11,014,810, where the Sepolia creation deposit sits, with a second
    # event in its block that the derivation cannot parse: the v0_no_calldata opaqueData under version 1.
    defp index_chunk_with_unparsable_event(json_rpc_named_arguments) do
      creation = deposit(:creation)["l1_event"]

      unparsable =
        deposit(:v0_no_calldata)["l1_event"]
        |> with_version(1)
        |> Map.merge(%{
          "blockHash" => creation["blockHash"],
          "blockNumber" => creation["blockNumber"],
          "logIndex" => "0x5c"
        })

      # Block numbers from events go out as they came; the others through EthereumJSONRPC.integer_to_quantity/1, which
      # writes upper-case hex.
      expect(EthereumJSONRPC.Mox, :json_rpc, 3, fn
        %{method: "eth_getLogs", params: [%{address: @portal, fromBlock: "0xA81290", toBlock: "0xA8129A"}]}, _options ->
          {:ok, [creation, unparsable]}

        [%{id: id, method: "eth_getBlockByNumber", params: ["0xa81294", true]}], _options ->
          transactions = [
            transaction_response(creation["transactionHash"], "0x7466be349b17a0f966f97ddeefe393894b9faf06"),
            transaction_response(unparsable["transactionHash"], "0x25b903c548436f3b563a5f6396071df82df560b5")
          ]

          {:ok, [%{id: id, result: block_response(11_014_804, transactions)}]}

        [%{id: id, method: "eth_getBlockByNumber", params: ["0xA8129A", false]}], _options ->
          {:ok, [%{id: id, result: block_response(11_014_810)}]}
      end)

      capture_log(fn ->
        assert {:noreply, %{start_block: 11_014_811, end_block: 11_014_900}} =
                 Deposit.handle_info(:continue, state(json_rpc_named_arguments, 11_014_800, 11_014_810))
      end)
    end

    defp state(json_rpc_named_arguments, start_block, end_block) do
      %{
        contract_address: @portal,
        block_check_interval: 12_000,
        start_block: start_block,
        end_block: end_block,
        json_rpc_named_arguments: json_rpc_named_arguments,
        eth_get_logs_range_size: 250
      }
    end

    defp with_version(%{"topics" => [signature, from, to, _version]} = event, version) do
      %{event | "topics" => [signature, from, to, hash(version)]}
    end

    defp hash(n), do: String.downcase("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0"))

    # Block object as returned by eth_getBlockByNumber.
    defp block_response(number, transactions \\ []) do
      %{
        "difficulty" => "0x0",
        "extraData" => "0x",
        "gasLimit" => "0x1c9c380",
        "gasUsed" => "0x0",
        "hash" => hash(number),
        "logsBloom" => "0x" <> String.duplicate("0", 512),
        "miner" => "0x0000000000000000000000000000000000000000",
        "mixHash" => "0x" <> String.duplicate("0", 64),
        "nonce" => "0x0000000000000000",
        "number" => "0x" <> Integer.to_string(number, 16),
        "parentHash" => "0x" <> String.duplicate("0", 64),
        "receiptsRoot" => "0x" <> String.duplicate("0", 64),
        "sha3Uncles" => "0x" <> String.duplicate("0", 64),
        "size" => "0x200",
        "stateRoot" => "0x" <> String.duplicate("0", 64),
        "timestamp" => "0x6846a3a0",
        "totalDifficulty" => "0x0",
        "transactions" => transactions,
        "transactionsRoot" => "0x" <> String.duplicate("0", 64),
        "uncles" => []
      }
    end

    # Transaction object as eth_getBlockByNumber returns it with full transactions.
    defp transaction_response(hash, from) do
      %{
        "blockHash" => hash(11_014_804),
        "blockNumber" => "0xa81294",
        "from" => from,
        "gas" => "0x5208",
        "gasPrice" => "0x3b9aca00",
        "hash" => hash,
        "input" => "0x",
        "nonce" => "0x0",
        "to" => @portal,
        "transactionIndex" => "0x0",
        "type" => "0x2",
        "value" => "0x0"
      }
    end
  end
end
