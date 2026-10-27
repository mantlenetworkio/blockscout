defmodule Indexer.Fetcher.Optimism.DepositTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import ExUnit.CaptureLog, only: [capture_log: 1]
    import Explorer.OptimismBridgeFixtures
    import Mox

    alias Explorer.Chain.Cache.Counters.LastFetchedCounter
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
    @counter_type "optimism_deposits_fetcher_last_l1_block_hash_v2"
    @counter_type_block "optimism_deposits_fetcher_last_l1_block_v2"

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

      test "returns nil for an event of an unknown version" do
        configure_bridges()
        event = with_version(deposit(:eth)["l1_event"], 2)

        log =
          capture_log(fn -> assert Deposit.event_to_deposit(event, %{}, %{}, 126, BridgeMessage.bridges()) == nil end)

        assert log =~ event["transactionHash"]
      end

      test "returns nil for an event whose opaqueData is too short for its version" do
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
      test "returns nil for a Mantle version 1 event" do
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

      # op-node halts on a deposit it cannot derive, so the chain has no such event: a failure to parse one is a
      # derivation bug or a configuration error (such as Mantle mode off on a Mantle chain), and the deposit's L2
      # transaction exists. Leaving the event out would lose the deposit for good, as the checkpoint moves on.
      test "imports nothing of a chunk with an event it cannot parse, and retries the chunk later", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        creation = deposit(:creation)["l1_event"]

        unparsable =
          deposit(:v0_no_calldata)["l1_event"]
          |> with_version(1)
          |> Map.merge(%{
            "blockHash" => creation["blockHash"],
            "blockNumber" => creation["blockNumber"],
            "logIndex" => "0x5c"
          })

        %{l2_transaction_hash: before_chunk} = insert(:op_deposit, l1_block_number: 11_014_700)
        %{l2_transaction_hash: in_chunk} = insert(:op_deposit, l1_block_number: 11_014_805)
        Optimism.set_last_block_hash(hash(11_014_799), @counter_type)
        put_stall_retry_interval(500)

        expect_chunk_requests([creation, unparsable])
        stub_checkpoint_request()

        log =
          capture_log(fn ->
            assert {:noreply, %{start_block: 11_014_800, end_block: 11_014_900}} =
                     Deposit.handle_info(:continue, state(json_rpc_named_arguments, 11_014_800, 11_014_810))
          end)

        # not right away: the chunk fails the same way until the fetcher or its configuration changes
        refute_received :continue

        assert [before_chunk, in_chunk] ==
                 Repo.all(from(d in DepositSchema, select: d.l2_transaction_hash, order_by: d.l1_block_number))

        assert String.downcase(Optimism.get_last_block_hash(@counter_type)) == hash(11_014_799)
        assert log =~ unparsable["transactionHash"]

        assert_receive :continue, 2_000
      end

      # While a deployment rolls over, a fetcher of the previous version keeps importing rows derived the previous way.
      # Its rows of the blocks of a chunk give way to the chunk's deposits; other rows stay.
      test "replaces the rows of the chunk's blocks that its deposits do not include", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        # the hash the previous version derived for the creation deposit
        {:ok, previous_hash} = Hash.Full.cast("0x8a1dcfe7ce0e40e130eed4809247d4ef81bd1ed888ece3f13f26501ee7156d24")
        insert(:op_deposit, l1_block_number: 11_014_804, l2_transaction_hash: previous_hash, l2_transaction: nil)
        %{l2_transaction_hash: before_chunk} = insert(:op_deposit, l1_block_number: 11_014_799)
        %{l2_transaction_hash: after_chunk} = insert(:op_deposit, l1_block_number: 11_014_811)

        index_creation_chunk(json_rpc_named_arguments)

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
        index_creation_chunk(json_rpc_named_arguments)

        assert {11_014_810, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)

        expect_checkpoint_lookup(11_014_810)
        state = state(json_rpc_named_arguments, 11_014_810, 11_014_900)

        assert state == Deposit.check_checkpoint(state)
        assert 1 == Repo.aggregate(DepositSchema, :count)
      end
    end

    describe "get_last_l1_item/1 and check_checkpoint/1" do
      setup do
        LatestL1BlockNumber.set_block_number(300)
        on_exit(fn -> ConCache.delete(LatestL1BlockNumber.cache_name(), :block_number) end)
      end

      # The deposits indexed before creation deposits and Mantle v0 events were derived the way op-node derives them
      # are checkpointed under the previous counter name only. They stay until the chunk of their L1 block replaces
      # them: the history stays visible meanwhile, and a rollback to the previous version finds it all.
      test "derives every deposit again from the start block, keeping the rows, without a checkpoint of its own", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        insert(:op_deposit, l1_block_number: 110)
        insert(:op_deposit, l1_block_number: 150)
        Optimism.set_last_block_hash(hash(150), "optimism_deposits_fetcher_last_l1_block_hash")

        assert {0, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)

        state = state(json_rpc_named_arguments, 1, 299)

        assert state == Deposit.check_checkpoint(state)
        assert [110, 150] == Repo.all(from(d in DepositSchema, select: d.l1_block_number, order_by: d.l1_block_number))
      end

      # An L1 reorg can replace the checkpoint block while the fetcher is down, unseen by the reorg monitor. The L1 node
      # can still return the replaced block by its hash, so the checkpoint is checked by its block number, and the
      # deposits are derived again from three epochs before it, as after a reorg reported at it, before the fetcher
      # handles any chunk: the deposits of the replaced blocks go, and those the replacing blocks include come.
      test "derives the deposits again from three epochs before a checkpoint block replaced while the fetcher was down",
           %{json_rpc_named_arguments: json_rpc_named_arguments} do
        %{l2_transaction_hash: kept} = insert(:op_deposit, l1_block_number: 250)
        insert(:op_deposit, l1_block_number: 340)
        put_checkpoint(350)

        assert {350, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)

        expect_checkpoint_lookup(350, hash(1_350))
        expect_rewind_requests(370, %{253 => block_response(253)})

        capture_log(fn ->
          assert %{start_block: 254} = Deposit.check_checkpoint(state(json_rpc_named_arguments, 350, 399))
        end)

        assert [kept] == Repo.all(from(d in DepositSchema, select: d.l2_transaction_hash))
        assert {253, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)
      end

      # A checkpoint of the previous version has the hash of its block only
      test "takes up after a checkpoint of the previous version, which names its block by the hash", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        Optimism.set_last_block_hash(hash(350), @counter_type)
        expect_block_by_hash(350)

        assert {350, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)

        expect_block_by_hash(350)
        expect_checkpoint_lookup(350)
        state = state(json_rpc_named_arguments, 350, 399)

        assert state == Deposit.check_checkpoint(state)
      end

      # While a deployment rolls over, or after a rollback, a fetcher of the previous version writes only the hash of the
      # checkpoint block, also when it rewinds after a reorg (here to block 853, removing the rows from block 854 on):
      # the fetcher takes up after the block of that hash, even before the block of its own checkpoint
      test "takes up after the block whose hash a fetcher of the previous version checkpointed last", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        put_checkpoint(1_000)
        Optimism.set_last_block_hash(hash(853), @counter_type)

        expect_block_by_hash(853)
        expect_checkpoint_lookup(853)

        assert %{start_block: 853} = Deposit.check_checkpoint(state(json_rpc_named_arguments, 1_000, 1_100))
      end

      # The previous version keeps no checkpoint when it rewinds to a block the L1 node does not return, and starts from
      # the start block on a restart: so does this version, rather than take up after its own checkpoint, which the
      # rewind removed the rows of
      test "takes up from the start block after a fetcher of the previous version left no checkpoint", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        put_checkpoint(1_000)
        Optimism.set_last_block_hash("0x" <> String.duplicate("0", 64), @counter_type)

        assert {0, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)
        assert %{start_block: 1} = Deposit.check_checkpoint(state(json_rpc_named_arguments, 1_000, 1_100))
      end

      test "takes up from the start block after a checkpoint of the previous version the L1 node does not find", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        put_checkpoint(1_000)
        Optimism.set_last_block_hash(hash(853), @counter_type)
        expect_block_by_hash(853, nil)

        assert %{start_block: 1} = Deposit.check_checkpoint(state(json_rpc_named_arguments, 1_000, 1_100))
      end

      # The block of a checkpoint hash is looked up again when it is checked: the cursor comes from that lookup
      test "takes up from the start block when the block of a checkpoint hash is gone when it is checked", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        Optimism.set_last_block_hash(hash(1_000), @counter_type)
        expect_block_by_hash(1_000)

        assert {1_000, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)

        expect_block_by_hash(1_000, nil)

        assert %{start_block: 1} = Deposit.check_checkpoint(state(json_rpc_named_arguments, 1_000, 1_100))
      end

      # The reorg monitor reports the block whose hash changed, which can be above the first block the reorg replaced,
      # and its report can be handled after the replacing blocks are finalized. So the fetcher derives the deposits
      # again from 96 blocks (three epochs) before the reported block, or from the first block that is not finalized
      # if that is earlier, and the checkpoint names the block before. Without one, a restart would take up from the
      # last row, which a fetcher of the previous version can import beyond the reorg while a deployment rolls over.
      # Here the fetcher handles blocks 300..399 when the monitor reports a reorg at block 380, and block 370 is
      # finalized.
      test "derives the deposits again from three epochs before an L1 reorg, also after a restart", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        %{l2_transaction_hash: kept} = insert(:op_deposit, l1_block_number: 270)
        insert(:op_deposit, l1_block_number: 290)
        insert(:op_deposit, l1_block_number: 350)
        RollupReorgMonitorQueue.push(380, Deposit)
        expect_reorg_requests(370, %{283 => block_response(283)})

        capture_log(fn ->
          assert {:noreply, %{start_block: 284}} =
                   Deposit.handle_info(:continue, state(json_rpc_named_arguments, 300, 399))
        end)

        assert [kept] == Repo.all(from(d in DepositSchema, select: d.l2_transaction_hash))

        # the previous version imports a deposit of a later block before the restart
        insert(:op_deposit, l1_block_number: 450)

        assert {283, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)

        expect_checkpoint_lookup(283)
        state = state(json_rpc_named_arguments, 283, 399)

        assert state == Deposit.check_checkpoint(state)
      end

      # Finality can lag far behind, as on a testnet that does not finalize: the deposits are derived again from the
      # first block that is not finalized
      test "derives the deposits again from the first unfinalized block after an L1 reorg deeper than three epochs", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        %{l2_transaction_hash: kept} = insert(:op_deposit, l1_block_number: 190)
        insert(:op_deposit, l1_block_number: 210)
        RollupReorgMonitorQueue.push(380, Deposit)
        expect_reorg_requests(200, %{200 => block_response(200)})

        capture_log(fn ->
          assert {:noreply, %{start_block: 201}} =
                   Deposit.handle_info(:continue, state(json_rpc_named_arguments, 300, 399))
        end)

        assert [kept] == Repo.all(from(d in DepositSchema, select: d.l2_transaction_hash))
      end

      # The rows are removed with the checkpoint written, so a checkpoint block the L1 node does not return is kept
      # without its hash: a restart derives the deposits again from before it, not from the start block
      # The checkpoint block of a reorg is below the blocks just handled, so an L1 node that does not return it lags
      # behind: the fetcher waits for it, as a checkpoint without a hash could not be told from one a fetcher of the
      # previous version leaves
      test "waits for the checkpoint block of an L1 reorg that the L1 node does not return yet", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        insert(:op_deposit, l1_block_number: 290)
        Optimism.set_last_block_hash(hash(350), @counter_type)
        RollupReorgMonitorQueue.push(380, Deposit)
        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getLogs"}, _options -> {:ok, []} end)
        expect_rewind_requests(370, %{283 => nil})
        expect_checkpoint_lookup(283)

        capture_log(fn ->
          assert {:noreply, %{start_block: 284}} =
                   Deposit.handle_info(:continue, state(json_rpc_named_arguments, 300, 399))
        end)

        assert [] == Repo.all(DepositSchema)
        assert {283, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)
      end

      # A checkpoint with a block number but no hash is no checkpoint of this version (it does not write one)
      test "takes up from the start block after a checkpoint with a block number and no hash", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        LastFetchedCounter.upsert(%{counter_type: @counter_type_block, value: 1_000 * Integer.pow(2, 256)})

        assert {0, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)
        assert %{start_block: 1} = Deposit.check_checkpoint(state(json_rpc_named_arguments, 1_000, 1_100))
      end

      # A checkpoint before the start block would stop the fetcher on a restart (`Optimism.init_continue/2`), so after a
      # reorg at the start block of a new deployment the fetcher takes up from the start block again, whatever rows a
      # fetcher of the previous version imports meanwhile
      test "takes up from the start block after an L1 reorg at it, also after a restart", %{
        json_rpc_named_arguments: json_rpc_named_arguments
      } do
        RollupReorgMonitorQueue.push(200, Deposit)
        expect_reorg_requests(150, %{})

        capture_log(fn ->
          assert {:noreply, %{start_block: 200}} =
                   Deposit.handle_info(:continue, state(json_rpc_named_arguments, 200, 299, 200))
        end)

        insert(:op_deposit, l1_block_number: 250)

        assert {0, nil, nil} = Deposit.get_last_l1_item(json_rpc_named_arguments)
      end
    end

    # The requests of a chunk without deposits that handles an L1 reorg: the logs, then those of the rewind (see
    # `expect_rewind_requests/2`)
    defp expect_reorg_requests(finalized_block, checkpoint_blocks) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getLogs"}, _options -> {:ok, []} end)
      expect_rewind_requests(finalized_block, checkpoint_blocks)
    end

    # The requests of a rewind after an L1 reorg: the finalized block, then the block of each checkpoint in
    # `checkpoint_blocks` (`nil` for a block the node does not return)
    defp expect_rewind_requests(finalized_block, checkpoint_blocks) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn [
                                                  %{
                                                    id: id,
                                                    method: "eth_getBlockByNumber",
                                                    params: ["finalized", false]
                                                  }
                                                ],
                                                _options ->
        {:ok, [%{id: id, result: block_response(finalized_block)}]}
      end)

      Enum.each(checkpoint_blocks, fn {number, block} ->
        expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getBlockByNumber", params: [quantity, false]},
                                                  _options ->
          assert EthereumJSONRPC.quantity_to_integer(quantity) == number
          {:ok, block}
        end)
      end)
    end

    # The block at the number of a checkpoint, as eth_getBlockByNumber gives it on a restart: with the hash `block_hash`,
    # by default that of the checkpoint
    defp expect_checkpoint_lookup(number, block_hash \\ nil) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getBlockByNumber", params: [quantity, false]},
                                                _options ->
        assert EthereumJSONRPC.quantity_to_integer(quantity) == number
        {:ok, %{block_response(number) | "hash" => block_hash || hash(number)}}
      end)
    end

    # The block of the hash of a checkpoint, as eth_getBlockByHash gives it on a restart (`nil` for a hash the node does
    # not find)
    defp expect_block_by_hash(number, block \\ :found) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "eth_getBlockByHash", params: [block_hash, false]},
                                                _options ->
        assert String.downcase(block_hash) == hash(number)
        {:ok, if(block == :found, do: block_response(number))}
      end)
    end

    # The checkpoint of L1 block `number`, as the fetcher writes it: the number and the hash in one value, and the hash
    # alone under the name of the previous version
    defp put_checkpoint(number) do
      Optimism.set_last_block_hash(hash(number), @counter_type)
      {block_hash, ""} = number |> hash() |> String.trim_leading("0x") |> Integer.parse(16)
      LastFetchedCounter.upsert(%{counter_type: @counter_type_block, value: number * Integer.pow(2, 256) + block_hash})
    end

    # Runs the fetcher over L1 blocks 11,014,800..11,014,810, where the Sepolia creation deposit sits.
    defp index_creation_chunk(json_rpc_named_arguments) do
      expect_chunk_requests([deposit(:creation)["l1_event"]])

      expect(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_getBlockByNumber", params: ["0xA8129A", false]}],
                                                _options ->
        {:ok, [%{id: id, result: block_response(11_014_810)}]}
      end)

      capture_log(fn ->
        assert {:noreply, %{start_block: 11_014_811, end_block: 11_014_900}} =
                 Deposit.handle_info(:continue, state(json_rpc_named_arguments, 11_014_800, 11_014_810))
      end)
    end

    # The logs of L1 blocks 11,014,800..11,014,810 and their block, 11,014,804. Block numbers from events go out as
    # they came; the others through EthereumJSONRPC.integer_to_quantity/1, which writes upper-case hex.
    defp expect_chunk_requests(events) do
      expect(EthereumJSONRPC.Mox, :json_rpc, 2, fn
        %{method: "eth_getLogs", params: [%{address: @portal, fromBlock: "0xA81290", toBlock: "0xA8129A"}]}, _options ->
          {:ok, events}

        [%{id: id, method: "eth_getBlockByNumber", params: ["0xa81294", true]}], _options ->
          transactions =
            Enum.map(events, &transaction_response(&1["transactionHash"], "0x7466be349b17a0f966f97ddeefe393894b9faf06"))

          {:ok, [%{id: id, result: block_response(11_014_804, transactions)}]}
      end)
    end

    defp put_stall_retry_interval(milliseconds) do
      previous = Application.get_env(:indexer, Deposit)
      Application.put_env(:indexer, Deposit, Keyword.put(previous || [], :stall_retry_interval, milliseconds))
      on_exit(fn -> Application.put_env(:indexer, Deposit, previous) end)
    end

    # The checkpoint of block 11,014,810, for a test that expects none.
    defp stub_checkpoint_request do
      stub(EthereumJSONRPC.Mox, :json_rpc, fn [%{id: id, method: "eth_getBlockByNumber", params: ["0xA8129A", false]}],
                                              _options ->
        {:ok, [%{id: id, result: block_response(11_014_810)}]}
      end)
    end

    # `start_block_l1` is the configured start block of the fetcher
    defp state(json_rpc_named_arguments, start_block, end_block, start_block_l1 \\ 1) do
      %{
        contract_address: @portal,
        block_check_interval: 12_000,
        start_block_l1: start_block_l1,
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
