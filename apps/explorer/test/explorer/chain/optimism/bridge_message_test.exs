defmodule Explorer.Chain.Optimism.BridgeMessageTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use ExUnit.Case, async: false

    import Explorer.OptimismBridgeFixtures

    alias Explorer.Chain.Optimism.{BridgeMessage, MessageRelay, Withdrawal}

    @l2_messenger "0x4200000000000000000000000000000000000007"
    @l2_standard_bridge "0x4200000000000000000000000000000000000010"
    @sepolia_l1_messenger "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c"
    @sepolia_aliased_l1_messenger "0x48ebc5312e31adb8bb0802fc72ca84da5cdfdc5d"
    @sepolia_l1_standard_bridge "0x21f308067241b2028503c07bd7cb3751ffab0fb2"
    @mainnet_l1_wst_bridge "0x2d001d79e5af5f65a939781fe228b267a8ed468b"
    @mainnet_l2_wst_bridge "0x9c46560d6209743968cc24150893631a39afde4d"
    @wsteth_l1 "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0"
    @wsteth_l2 "0x458ed78eb972a369799fb278c0243b25e5242a83"
    @victim "0x000000000000000000000000000000000000beef"
    @attacker "0x000000000000000000000000000000000000bad0"

    describe "bridges/0" do
      test "aliases the L1 messenger and defaults the L2 standard bridge" do
        configure_bridges()

        assert BridgeMessage.bridges() == %{
                 l1_cross_domain_messenger: @sepolia_l1_messenger,
                 aliased_l1_cross_domain_messenger: @sepolia_aliased_l1_messenger,
                 l2_cross_domain_messenger: @l2_messenger,
                 l1_standard_bridge: @sepolia_l1_standard_bridge,
                 l2_standard_bridge: @l2_standard_bridge,
                 l1_wst_bridge: nil,
                 l2_wst_bridge: nil
               }
      end

      test "is nil without the L1 standard bridge, and nothing is decoded then" do
        configure_bridges()
        put_optimism_env(l1_standard_bridge: nil)

        assert BridgeMessage.bridges() == nil
        assert BridgeMessage.decode_withdrawal(withdrawal_message(withdrawal(:eth)), nil) == %{}
        assert BridgeMessage.decode_deposit(deposit_message(deposit(:eth)), nil) == %{}
      end

      test "is nil when the L1 messenger is not an address" do
        configure_bridges()
        Application.put_env(:indexer, Indexer.Fetcher.Optimism.MessageRelayL1, l1_cross_domain_messenger: "0x1234")

        assert BridgeMessage.bridges() == nil
      end
    end

    test "apply_l1_to_l2_alias/1 adds the alias offset modulo 2^160" do
      assert BridgeMessage.apply_l1_to_l2_alias(@sepolia_l1_messenger) == @sepolia_aliased_l1_messenger

      assert BridgeMessage.apply_l1_to_l2_alias("0xffffffffffffffffffffffffffffffffffffffff") ==
               "0x1111000000000000000000000000000000001110"
    end

    test "topic_to_address/1 takes the last 20 bytes of a topic" do
      assert BridgeMessage.topic_to_address("0x0000000000000000000000004200000000000000000000000000000000000007") ==
               @l2_messenger

      assert BridgeMessage.topic_to_address(nil) == nil
    end

    describe "decode_withdrawal/2" do
      for name <- [:eth, :mnt, :erc20, :message] do
        test "decodes the Sepolia #{name} withdrawal" do
          configure_bridges()
          fixture = withdrawal(unquote(name))

          assert BridgeMessage.decode_withdrawal(withdrawal_message(fixture), BridgeMessage.bridges()) ==
                   expected_transfer(fixture)
        end
      end

      test "decodes a mainnet wstETH withdrawal through the wst bridges" do
        configure_bridges(:mainnet)
        fixture = withdrawal(:wst_mainnet)

        assert BridgeMessage.decode_withdrawal(withdrawal_message(fixture), BridgeMessage.bridges()) ==
                 expected_transfer(fixture)
      end

      test "a wstETH withdrawal is a message between the wst bridges when they are not configured" do
        configure_bridges(:mainnet)
        put_optimism_env(l1_wst_bridge: nil, l2_wst_bridge: nil)
        fixture = withdrawal(:wst_mainnet)

        assert %{
                 transfer_type: :message,
                 transfer_from_address_hash: @mainnet_l2_wst_bridge,
                 transfer_to_address_hash: @mainnet_l1_wst_bridge,
                 l1_token_address_hash: nil,
                 transfer_amount: nil
               } = transfer = BridgeMessage.decode_withdrawal(withdrawal_message(fixture), BridgeMessage.bridges())

        assert transfer.message_hash == expected_transfer(fixture).message_hash
      end

      test "the OP Stack relayMessage carries one value, the ETH one" do
        configure_bridges()

        calldata =
          call(
            <<0xD7, 0x64, 0xAD, 0x0B>>,
            [{:uint, 256}, :address, :address, {:uint, 256}, {:uint, 256}, :bytes],
            [1, bin(@l2_standard_bridge), bin(@sepolia_l1_standard_bridge), 3, 0, finalize_eth(@victim, @victim, 3)]
          )

        message = %{from: @l2_messenger, to: @sepolia_l1_messenger, data: calldata, mnt_value: nil, eth_value: 3}

        assert %{
                 transfer_type: :eth,
                 transfer_to_address_hash: @victim,
                 transfer_amount: 3,
                 mnt_value: nil,
                 eth_value: 3
               } =
                 BridgeMessage.decode_withdrawal(message, BridgeMessage.bridges())
      end

      test "decodes the messages of one transaction one by one (LD1)" do
        configure_bridges()
        bridges = BridgeMessage.bridges()

        assert Enum.map([:eth, :erc20], &BridgeMessage.decode_withdrawal(withdrawal_message(withdrawal(&1)), bridges)) ==
                 Enum.map([:eth, :erc20], &expected_transfer(withdrawal(&1)))
      end
    end

    describe "decode_deposit/2" do
      for name <- [:eth, :mnt, :erc20, :message] do
        test "decodes the Sepolia #{name} deposit" do
          configure_bridges()
          fixture = deposit(unquote(name))

          assert BridgeMessage.decode_deposit(deposit_message(fixture), BridgeMessage.bridges()) ==
                   expected_transfer(fixture)
        end
      end

      test "a wstETH finalizeDeposit through the wst bridges names both tokens" do
        configure_bridges(:mainnet)
        bridges = BridgeMessage.bridges()

        inner =
          call(<<0x66, 0x2A, 0x63, 0x3A>>, [:address, :address, :address, :address, {:uint, 256}, :bytes], [
            bin(@wsteth_l1),
            bin(@wsteth_l2),
            bin(@attacker),
            bin(@victim),
            5,
            ""
          ])

        message = %{
          from: bridges.aliased_l1_cross_domain_messenger,
          to: @l2_messenger,
          data: mantle_relay(@mainnet_l1_wst_bridge, @mainnet_l2_wst_bridge, inner),
          mnt_value: 0,
          eth_value: 0
        }

        assert %{
                 transfer_type: :erc20,
                 transfer_from_address_hash: @attacker,
                 transfer_to_address_hash: @victim,
                 l1_token_address_hash: @wsteth_l1,
                 l2_token_address_hash: @wsteth_l2,
                 transfer_amount: 5
               } = BridgeMessage.decode_deposit(message, bridges)
      end
    end

    describe "authentication" do
      test "a MessagePassed not sent by the L2 messenger is a message between its own sender and target" do
        configure_bridges()
        message = %{withdrawal_message(withdrawal(:eth)) | from: @attacker}

        assert BridgeMessage.decode_withdrawal(message, BridgeMessage.bridges()) == %{
                 message_hash: nil,
                 transfer_type: :message,
                 transfer_from_address_hash: @attacker,
                 transfer_to_address_hash: @sepolia_l1_messenger,
                 l1_token_address_hash: nil,
                 l2_token_address_hash: nil,
                 transfer_amount: nil,
                 mnt_value: 0,
                 eth_value: 100_000_000_000_000
               }
      end

      test "a deposit not sent by the aliased L1 messenger is a message between its own from and to" do
        configure_bridges()
        message = %{deposit_message(deposit(:eth)) | from: @attacker}

        assert %{
                 transfer_type: :message,
                 message_hash: nil,
                 transfer_from_address_hash: @attacker,
                 transfer_to_address_hash: @l2_messenger
               } = BridgeMessage.decode_deposit(message, BridgeMessage.bridges())
      end

      test "a deposit of the aliased messenger to another address is not a messenger message" do
        configure_bridges()
        message = %{deposit_message(deposit(:eth)) | to: @victim}

        assert %{transfer_type: :message, message_hash: nil, transfer_to_address_hash: @victim} =
                 BridgeMessage.decode_deposit(message, BridgeMessage.bridges())
      end

      test "a bridge payload sent by a contract that is not the bridge is not attributed to its recipient" do
        configure_bridges()
        calldata = mantle_relay(@attacker, @sepolia_l1_standard_bridge, finalize_eth(@attacker, @victim, 10 ** 24))
        message = %{from: @l2_messenger, to: @sepolia_l1_messenger, data: calldata, mnt_value: 0, eth_value: 0}

        transfer = BridgeMessage.decode_withdrawal(message, BridgeMessage.bridges())

        assert %{
                 transfer_type: :message,
                 transfer_from_address_hash: @attacker,
                 transfer_to_address_hash: @sepolia_l1_standard_bridge,
                 transfer_amount: nil
               } = transfer

        refute @victim in Map.values(transfer)
        # the message itself is authentic, so its relay can still be followed
        assert transfer.message_hash == to_string(MessageRelay.message_hash(calldata))
      end

      test "the bridge pair of the other direction is not a transfer" do
        configure_bridges()
        calldata = mantle_relay(@sepolia_l1_standard_bridge, @l2_standard_bridge, finalize_eth(@victim, @victim, 1))
        message = %{from: @l2_messenger, to: @sepolia_l1_messenger, data: calldata, mnt_value: 0, eth_value: 0}

        assert %{transfer_type: :message, transfer_amount: nil} =
                 BridgeMessage.decode_withdrawal(message, BridgeMessage.bridges())
      end

      test "an unknown call between the bridges is a message between the bridges" do
        configure_bridges()
        calldata = mantle_relay(@l2_standard_bridge, @sepolia_l1_standard_bridge, <<0xDE, 0xAD, 0xBE, 0xEF>>)
        message = %{from: @l2_messenger, to: @sepolia_l1_messenger, data: calldata, mnt_value: 0, eth_value: 0}

        assert %{
                 transfer_type: :message,
                 transfer_from_address_hash: @l2_standard_bridge,
                 transfer_to_address_hash: @sepolia_l1_standard_bridge
               } = BridgeMessage.decode_withdrawal(message, BridgeMessage.bridges())
      end

      test "a truncated relayMessage falls back to the outer message" do
        configure_bridges()

        message = %{
          from: @l2_messenger,
          to: @sepolia_l1_messenger,
          data: <<0xFF, 0x8D, 0xAF, 0x15, 1, 2, 3>>,
          mnt_value: 1,
          eth_value: 2
        }

        assert %{
                 transfer_type: :message,
                 message_hash: nil,
                 transfer_from_address_hash: @l2_messenger,
                 mnt_value: 1,
                 eth_value: 2
               } = BridgeMessage.decode_withdrawal(message, BridgeMessage.bridges())
      end
    end

    describe "Withdrawal.parse_message_passed_data/2" do
      test "reads the Mantle layout" do
        %{"message_passed" => %{"data" => data}} = withdrawal(:eth)

        assert %{mnt_value: 0, eth_value: 100_000_000_000_000, data: <<0xFF, 0x8D, 0xAF, 0x15, _::binary>>} =
                 Withdrawal.parse_message_passed_data(data, true)
      end

      test "reads the OP Stack layout" do
        data =
          "0x" <>
            Base.encode16(
              ABI.TypeEncoder.encode([5, 6, <<1>>, <<0::256>>], [{:uint, 256}, {:uint, 256}, :bytes, {:bytes, 32}])
            )

        assert %{mnt_value: nil, eth_value: 5, gas_limit: 6, data: <<1>>} =
                 Withdrawal.parse_message_passed_data(data, false)
      end
    end

    defp withdrawal_message(%{"message_passed" => %{"topics" => [_, _, sender, target], "data" => data}}) do
      parsed = Withdrawal.parse_message_passed_data(data, true)

      %{
        from: BridgeMessage.topic_to_address(sender),
        to: BridgeMessage.topic_to_address(target),
        data: parsed.data,
        mnt_value: parsed.mnt_value,
        eth_value: parsed.eth_value
      }
    end

    # A deposit as its L2 transaction carries it: the relayMessage calldata, sent by the aliased messenger. The values
    # of an authenticated message come from its calldata, so the outer ones do not matter here.
    defp deposit_message(%{"l2_transaction_from" => from, "l2_transaction_input" => input}) do
      %{from: from, to: @l2_messenger, data: bin(input), mnt_value: 0, eth_value: 0}
    end

    defp put_optimism_env(values) do
      Application.put_env(
        :indexer,
        Indexer.Fetcher.Optimism,
        Keyword.merge(Application.get_env(:indexer, Indexer.Fetcher.Optimism), values)
      )
    end

    defp mantle_relay(sender, target, inner) do
      call(
        <<0xFF, 0x8D, 0xAF, 0x15>>,
        [{:uint, 256}, :address, :address, {:uint, 256}, {:uint, 256}, {:uint, 256}, :bytes],
        [1, bin(sender), bin(target), 0, 0, 200_000, inner]
      )
    end

    defp finalize_eth(from, to, amount) do
      call(<<0x16, 0x35, 0xF5, 0xFD>>, [:address, :address, {:uint, 256}, :bytes], [bin(from), bin(to), amount, ""])
    end

    defp call(selector, types, values), do: selector <> ABI.TypeEncoder.encode(values, types)

    defp bin("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  end
end
