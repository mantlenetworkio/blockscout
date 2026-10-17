defmodule Explorer.Chain.Optimism.LegacyBridgeMessageTest do
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  if @chain_type == :optimism do
    use ExUnit.Case, async: false

    import Explorer.OptimismLegacyBridgeFixtures

    alias Explorer.Chain.Optimism.{BridgeMessage, LegacyBridgeMessage}

    @l2_standard_bridge "0x4200000000000000000000000000000000000010"

    describe "decode_withdrawal/2" do
      for name <- [:eth, :mnt, :erc20, :message_mainnet, :eth_mainnet] do
        test "gives the #{name} v1 withdrawal its transfer and migrated identity" do
          fixture = legacy_withdrawal(unquote(name))
          configure_legacy_bridges(fixture["network"])

          sent_message = LegacyBridgeMessage.sent_message(fixture["sent_message"])

          assert LegacyBridgeMessage.decode_withdrawal(sent_message, BridgeMessage.bridges()) ==
                   expected_legacy(fixture)
        end
      end

      test "a bridge payload sent by another contract is a message whose migrated values are 0" do
        fixture = legacy_withdrawal(:eth)
        configure_legacy_bridges(fixture["network"])

        sent_message = %{
          LegacyBridgeMessage.sent_message(fixture["sent_message"])
          | sender: "0x000000000000000000000000000000000000bad0"
        }

        decoded = LegacyBridgeMessage.decode_withdrawal(sent_message, BridgeMessage.bridges())

        assert %{
                 transfer_type: :message,
                 transfer_amount: nil,
                 transfer_from_address_hash: "0x000000000000000000000000000000000000bad0"
               } =
                 decoded

        assert relay_values(decoded.migrated_msg_data) == {0, 0}
      end

      test "the L2StandardBridge's ETH to another target keeps its migrated value but is a message" do
        fixture = legacy_withdrawal(:eth)
        configure_legacy_bridges(fixture["network"])

        sent_message = %{
          LegacyBridgeMessage.sent_message(fixture["sent_message"])
          | target: "0x000000000000000000000000000000000000beef"
        }

        decoded = LegacyBridgeMessage.decode_withdrawal(sent_message, BridgeMessage.bridges())

        assert %{transfer_type: :message, transfer_to_address_hash: "0x000000000000000000000000000000000000beef"} =
                 decoded

        assert relay_values(decoded.migrated_msg_data) == {0, expected_legacy(fixture).transfer_amount}
      end

      test "garbage from the bridge is a message between the bridges" do
        fixture = legacy_withdrawal(:mnt)
        configure_legacy_bridges(fixture["network"])

        sent_message = %{
          LegacyBridgeMessage.sent_message(fixture["sent_message"])
          | message: <<0xF8, 0x2B, 0x41, 0x8E, 1>>
        }

        assert %{transfer_type: :message, transfer_from_address_hash: @l2_standard_bridge} =
                 LegacyBridgeMessage.decode_withdrawal(sent_message, BridgeMessage.bridges())
      end
    end

    describe "decode_deposit/2" do
      for name <- [:eth, :mnt, :erc20, :message] do
        test "gives the #{name} v1 deposit its transfer and the v0 hash its L2 relay carries" do
          fixture = legacy_deposit(unquote(name))
          configure_legacy_bridges(fixture["network"])

          decoded =
            fixture["sent_message"]
            |> LegacyBridgeMessage.sent_message()
            |> LegacyBridgeMessage.decode_deposit(BridgeMessage.bridges())

          assert decoded == expected_legacy(fixture)
          assert decoded.message_hash == fixture["relay"]["message_hash"]
        end
      end
    end

    test "sent_message/1 leaves out messages that are not v1 (version 0) ones" do
      %{"sent_message" => log} = legacy_withdrawal(:eth)
      [sender, message, nonce, gas_limit] = decode_sent_message_data(log["data"])
      v2_nonce = Bitwise.bor(Bitwise.bsl(1, 240), nonce)

      data =
        "0x" <>
          Base.encode16(
            ABI.TypeEncoder.encode([sender, message, v2_nonce, gas_limit], [
              :address,
              :bytes,
              {:uint, 256},
              {:uint, 256}
            ]),
            case: :lower
          )

      assert LegacyBridgeMessage.sent_message(%{log | "data" => data}) == nil
      assert %{nonce: ^nonce} = LegacyBridgeMessage.sent_message(log)
    end

    defp decode_sent_message_data("0x" <> hex) do
      hex |> Base.decode16!(case: :lower) |> ABI.TypeDecoder.decode_raw([:address, :bytes, {:uint, 256}, {:uint, 256}])
    end

    # The MNT and ETH values a migrated relayMessage calldata delivers
    defp relay_values("0x" <> hex) do
      <<0xFF, 0x8D, 0xAF, 0x15, arguments::binary>> = Base.decode16!(hex, case: :lower)

      [_nonce, _sender, _target, mnt_value, eth_value, _min_gas_limit, _message] =
        ABI.TypeDecoder.decode_raw(arguments, [
          {:uint, 256},
          :address,
          :address,
          {:uint, 256},
          {:uint, 256},
          {:uint, 256},
          :bytes
        ])

      {mnt_value, eth_value}
    end
  end
end
