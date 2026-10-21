defmodule Explorer.Chain.Optimism.MessageRelayTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use Explorer.DataCase, async: false

    alias Explorer.Chain
    alias Explorer.Chain.Optimism.{MessageRelay, WithdrawalEvent}
    alias Explorer.{QueryPlanHelper, Repo, TestHelper}

    @relayed "0x4641df4a962071e12719d8c8c8e5ac7fc4d97b927346a3d7a335b1f7517e133c"
    @failed "0x99d0e048484baa1b1540b1367cb128acd7ab2946d1ed91ec10e3c85e4bf51b8f"

    # relayMessage(uint256,address,address,uint256,uint256,bytes)(1, 0x…01, 0x…02, 5, 0, 0x6869) and its keccak256,
    # both produced with viem.
    @op_calldata "0xd764ad0b0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000026869000000000000000000000000000000000000000000000000000000000000"
    @op_message_hash "0x77ca0fe83f9410b1abcaf3f3b42be0243c29b60c8b9895453bb5cccab720428e"

    defp hash(n), do: String.downcase("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0"))

    defp log(signature, message_hash, transaction_hash, block_number) do
      %{
        "topics" => [signature, message_hash],
        "transactionHash" => transaction_hash,
        "blockNumber" => "0x" <> Integer.to_string(block_number, 16)
      }
    end

    defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :lower)

    defmodule RecordingRepo do
      @moduledoc false
      def all(_queryable, _options) do
        send(self(), :recording_repo_read)
        []
      end
    end

    describe "events_to_relays/2" do
      test "maps both events and drops duplicates and unrelated topics" do
        events = [
          log(@failed, hash(1), hash(100), 10),
          log(@failed, hash(1), hash(100), 10),
          log(@relayed, hash(1), hash(101), 11),
          log(hash(999), hash(2), hash(102), 12)
        ]

        assert MessageRelay.events_to_relays(events, :l2) == [
                 %{
                   message_hash: hash(1),
                   event_type: :FailedRelayedMessage,
                   transaction_hash: hash(100),
                   chain: :l2,
                   block_number: 10
                 },
                 %{
                   message_hash: hash(1),
                   event_type: :RelayedMessage,
                   transaction_hash: hash(101),
                   chain: :l2,
                   block_number: 11
                 }
               ]
      end
    end

    describe "import and summaries/3" do
      test "keeps every failure, ignores re-imports, and lets a later replay win" do
        relays =
          MessageRelay.events_to_relays(
            [
              log(@failed, hash(1), hash(100), 10),
              log(@failed, hash(1), hash(101), 11),
              log(@relayed, hash(1), hash(102), 12),
              log(@failed, hash(2), hash(103), 13)
            ],
            :l1
          )

        {:ok, _} = Chain.import(%{optimism_message_relays: %{params: relays}, timeout: :infinity})
        {:ok, _} = Chain.import(%{optimism_message_relays: %{params: relays}, timeout: :infinity})

        assert Repo.aggregate(MessageRelay, :count) == 4

        message_hashes = [TestHelper.topic(hash(1)), TestHelper.topic(hash(2)), TestHelper.topic(hash(3))]

        assert MessageRelay.summaries(message_hashes, :l1) == %{
                 TestHelper.topic(hash(1)) => %{status: :relayed, transaction_hash: TestHelper.topic(hash(102))},
                 TestHelper.topic(hash(2)) => %{status: :failed, transaction_hash: nil}
               }
      end

      test "reads only the relays of the requested chain" do
        message_hash = TestHelper.topic(hash(5))
        insert(:op_message_relay, message_hash: message_hash, chain: :l2)

        assert MessageRelay.summaries([message_hash], :l1) == %{}
        assert %{^message_hash => %{status: :relayed}} = MessageRelay.summaries([message_hash], :l2)
      end

      # A page reads its rows and their relays with two queries; with the replica, a choice made for each could read
      # the relays from a replica behind the rows
      test "reads from the repo it is given" do
        assert MessageRelay.summaries([TestHelper.topic(hash(1))], :l1, repo: RecordingRepo) == %{}
        assert_received :recording_repo_read
      end

      test "returns an empty map for no hashes" do
        assert MessageRelay.summaries([], :l1) == %{}
      end

      test "probes each hash through the primary key with a limit, however many failures it has" do
        insert_unrelated_relays(1_000)
        message_hash = TestHelper.topic(hash(1))

        for block_number <- 1..50 do
          insert(:op_message_relay,
            message_hash: message_hash,
            event_type: :FailedRelayedMessage,
            chain: :l1,
            block_number: block_number
          )
        end

        plan = QueryPlanHelper.plan("op_message_relays", fn -> MessageRelay.summaries([message_hash], :l1) end)

        assert plan =~ ~r/Limit.*\n\s*->\s+Index (Only )?Scan using op_message_relays_pkey/

        assert MessageRelay.summaries([message_hash], :l1) == %{
                 message_hash => %{status: :failed, transaction_hash: nil}
               }
      end
    end

    describe "message_hash/1" do
      test "is the hash the messenger emitted, for the Mantle and the OP Stack relayMessage" do
        assert to_string(MessageRelay.message_hash(bytes(op_relay_message_calldata()))) == op_relay_message_hash()
        assert to_string(MessageRelay.message_hash(bytes(@op_calldata))) == @op_message_hash
      end

      test "is nil for anything that is not a relayMessage call" do
        assert MessageRelay.message_hash(<<0xA9, 0x05, 0x9C, 0xBB, 0::256>>) == nil
        assert MessageRelay.message_hash(<<>>) == nil
        assert MessageRelay.message_hash(nil) == nil
      end
    end

    describe "last_relay_query/1" do
      test "skips the v1 era of a chain whose legacy history is rebuilt from its ranges" do
        legacy = Application.get_env(:indexer, Indexer.Fetcher.Optimism.LegacyBridge)

        Application.put_env(
          :indexer,
          Indexer.Fetcher.Optimism.LegacyBridge,
          Keyword.merge(legacy || [], l2_end_block: 1_000, l1_end_block: 10_000)
        )

        on_exit(fn -> Application.put_env(:indexer, Indexer.Fetcher.Optimism.LegacyBridge, legacy) end)

        insert(:op_message_relay, chain: :l2, block_number: 1_000)
        insert(:op_message_relay, chain: :l1, block_number: 10_000)

        assert Repo.one(MessageRelay.last_relay_query(:l2)) == nil
        assert Repo.one(MessageRelay.last_relay_query(:l1)) == nil

        later = insert(:op_message_relay, chain: :l2, block_number: 1_001)
        assert Repo.one(MessageRelay.last_relay_query(:l2)) == {1_001, later.transaction_hash}
      end
    end

    describe "last_relay_query/1 with relays imported by the withdrawal event fetcher" do
      # That fetcher imports the relay of a finalizing transaction with the finalization, ahead of the relay fetcher,
      # so such a relay does not show how far the relay fetcher scanned
      test "leaves out the L1 relays of finalizing transactions" do
        replay = insert(:op_message_relay, chain: :l1, block_number: 120)
        finalization = insert(:op_message_relay, chain: :l1, block_number: 150)

        Repo.insert!(%WithdrawalEvent{
          withdrawal_hash: transaction_hash(),
          l1_event_type: :WithdrawalFinalized,
          l1_timestamp: DateTime.utc_now(),
          l1_transaction_hash: finalization.transaction_hash,
          l1_block_number: 150
        })

        assert Repo.one(MessageRelay.last_relay_query(:l1)) == {120, replay.transaction_hash}
      end

      test "is nil when every L1 relay is in a finalizing transaction, so that the relay fetcher scans from its start" do
        finalization = insert(:op_message_relay, chain: :l1, block_number: 150)

        Repo.insert!(%WithdrawalEvent{
          withdrawal_hash: transaction_hash(),
          l1_event_type: :WithdrawalFinalized,
          l1_timestamp: DateTime.utc_now(),
          l1_transaction_hash: finalization.transaction_hash,
          l1_block_number: 150
        })

        assert Repo.one(MessageRelay.last_relay_query(:l1)) == nil
      end
    end

    describe "l2_cross_domain_messenger/0" do
      test "defaults to the predeploy" do
        assert MessageRelay.l2_cross_domain_messenger() == "0x4200000000000000000000000000000000000007"
      end
    end

    # Relays of other messages, so that the planner weighs the primary key against a table that is not empty
    defp insert_unrelated_relays(count) do
      now = DateTime.utc_now()

      rows =
        for block_number <- 1..count do
          %{
            message_hash: transaction_hash(),
            event_type: :RelayedMessage,
            transaction_hash: transaction_hash(),
            chain: :l1,
            block_number: block_number,
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(MessageRelay, rows)
    end
  end
end
