defmodule Explorer.Chain.Optimism.LegacyBridgeMessage do
  @moduledoc """
    Decodes Mantle v1 (pre-Bedrock) cross-domain messages: the bridge transfer a legacy `SentMessage` carries, its v0
    message hash, which the legacy messengers emit in their relay events, and for a withdrawal the identity the
    Bedrock migration gave it, under which the v2 portal proves and finalizes it and the v2 messenger relays it.

    Transfers are typed with the rule of `Explorer.Chain.Optimism.BridgeMessage`: only a message between the standard
    bridges, in its direction, is a transfer; anything else is a `message` between the messenger-level sender and
    target. The migrated identity ports `MigrateWithdrawal` of mantle-v2 op-chain-ops v1.0.0-alpha.3. Every hash it
    gives must be in `L2ToL1MessagePasser.sentMessages`, which `Indexer.Fetcher.Optimism.LegacyBridge` checks before
    the rows are served.
  """

  import Bitwise

  alias Explorer.Chain.Optimism.BridgeMessage

  # 32-byte signature of SentMessage(address indexed target, address sender, bytes message, uint256 messageNonce,
  # uint256 gasLimit), the same in the legacy and the Bedrock messengers
  @sent_message_event "0xcb0f7ffd78f9aee47a248fae8db181db6eee833039123e026dcbff529522e52a"

  # relayMessage(address,address,bytes,uint256) of the legacy messengers
  @relay_message_v0 <<0xCB, 0xD4, 0xEC, 0xE9>>
  # relayMessage(uint256,address,address,uint256,uint256,uint256,bytes) of the Mantle Bedrock messengers
  @relay_message_v1 <<0xFF, 0x8D, 0xAF, 0x15>>

  # finalizeDeposit(address,address,address,address,uint256,bytes) of the legacy L2StandardBridge
  @finalize_deposit <<0x66, 0x2A, 0x63, 0x3A>>
  # finalizeETHWithdrawal(address,address,uint256,bytes) of the legacy L1StandardBridge
  @finalize_eth_withdrawal <<0x15, 0x32, 0xEC, 0x34>>
  # finalizeMantleWithdrawal(address,address,uint256,bytes) of the legacy L1StandardBridge
  @finalize_mantle_withdrawal <<0xF8, 0x2B, 0x41, 0x8E>>
  # finalizeERC20Withdrawal(address,address,address,address,uint256,bytes) of the legacy L1StandardBridge
  @finalize_erc20_withdrawal <<0xA9, 0xF9, 0xE6, 0x75>>

  # The L2 token a legacy ETH / MNT deposit names
  @bvm_eth "0xdeaddeaddeaddeaddeaddeaddeaddeaddead1111"
  @legacy_mnt "0xdeaddeaddeaddeaddeaddeaddeaddeaddead0000"

  # MigrateWithdrawalGasLimit: 16 gas per byte of the migrated message, plus a fixed overhead of 200_000 +
  # 64_000_000 / 63 + 40_000 + 40_000 + 5_000, capped at 25_000_000. These are the constants of the migration; with
  # any other value no migrated hash matches the L2ToL1MessagePasser.
  @migrated_gas_overhead 200_000 + div(64_000_000, 63) + 40_000 + 40_000 + 5_000
  @migrated_gas_cap 25_000_000

  @native_arguments [:address, :address, {:uint, 256}, :bytes]
  @erc20_arguments [:address, :address, :address, :address, {:uint, 256}, :bytes]

  @type sent_message :: %{target: String.t(), sender: String.t(), message: binary(), nonce: non_neg_integer()}

  @doc "Returns the `topic0` of the `SentMessage` event."
  @spec sent_message_event() :: String.t()
  def sent_message_event, do: @sent_message_event

  @doc """
    Reads a `SentMessage` log as returned by `eth_getLogs`. Returns `nil` unless it is a v1 message, which a version 0
    nonce tells: the same messengers emit v2 (version 1) messages after the upgrade.
  """
  @spec sent_message(map()) :: sent_message() | nil
  def sent_message(%{"topics" => [signature, target_topic | _], "data" => "0x" <> data}) do
    with @sent_message_event <- String.downcase(signature),
         {:ok, bytes} <- Base.decode16(data, case: :mixed),
         [sender, message, nonce, _gas_limit] <- decode(bytes, [:address, :bytes, {:uint, 256}, {:uint, 256}]),
         0 <- nonce >>> 240 do
      %{
        target: BridgeMessage.topic_to_address(target_topic),
        sender: address_string(sender),
        message: message,
        nonce: nonce
      }
    else
      _ -> nil
    end
  end

  def sent_message(_log), do: nil

  @doc """
    Returns the v0 hash of a v1 message: `keccak256` of the legacy `relayMessage(target, sender, message, nonce)`
    calldata, which the legacy messengers emit in `RelayedMessage` / `FailedRelayedMessage`.
  """
  @spec v0_message_hash(sent_message()) :: String.t()
  def v0_message_hash(%{target: target, sender: sender, message: message, nonce: nonce}) do
    @relay_message_v0
    |> Kernel.<>(
      ABI.TypeEncoder.encode([bytes(target), bytes(sender), message, nonce], [:address, :address, :bytes, {:uint, 256}])
    )
    |> hash()
  end

  @doc """
    Decodes a v1 deposit (an L1 `SentMessage`): its transfer and `message_hash` (v0). Returns `%{}` when `bridges` is
    `nil`.
  """
  @spec decode_deposit(sent_message(), BridgeMessage.bridges() | nil) :: map()
  def decode_deposit(_sent_message, nil), do: %{}

  def decode_deposit(sent_message, bridges) do
    transfer =
      if {sent_message.sender, sent_message.target} == {bridges.l1_standard_bridge, bridges.l2_standard_bridge},
        do: deposit_transfer(sent_message.message),
        else: nil

    message(sent_message, transfer)
  end

  @doc """
    Decodes a v1 withdrawal (an L2 `SentMessage`): its transfer, `message_hash` (v0), and its identity after the
    migration: `migrated_withdrawal_hash`, `migrated_message_hash`, `migrated_msg_data` (0x string) and
    `migrated_gas_limit`. Returns `%{}` when `bridges` is `nil`.
  """
  @spec decode_withdrawal(sent_message(), BridgeMessage.bridges() | nil) :: map()
  def decode_withdrawal(_sent_message, nil), do: %{}

  def decode_withdrawal(sent_message, bridges) do
    transfer =
      if {sent_message.sender, sent_message.target} == {bridges.l2_standard_bridge, bridges.l1_standard_bridge},
        do: withdrawal_transfer(sent_message.message),
        else: nil

    sent_message
    |> message(transfer)
    |> Map.merge(migrated_identity(sent_message, bridges))
  end

  # MigrateWithdrawal: the v1 message wrapped into the Bedrock messenger's relayMessage with the values it delivers,
  # sent from the L2 to the L1 messenger
  defp migrated_identity(%{nonce: nonce} = sent_message, bridges) do
    {mnt_value, eth_value} = migrated_values(sent_message, bridges)

    data =
      @relay_message_v1 <>
        ABI.TypeEncoder.encode(
          [
            nonce,
            bytes(sent_message.sender),
            bytes(sent_message.target),
            mnt_value,
            eth_value,
            0,
            sent_message.message
          ],
          [{:uint, 256}, :address, :address, {:uint, 256}, {:uint, 256}, {:uint, 256}, :bytes]
        )

    gas_limit = min(byte_size(data) * 16 + @migrated_gas_overhead, @migrated_gas_cap)

    withdrawal_hash =
      [nonce, bytes(bridges.l2_cross_domain_messenger), bytes(bridges.l1_cross_domain_messenger), mnt_value, eth_value]
      |> Kernel.++([gas_limit, data])
      |> ABI.TypeEncoder.encode([{:uint, 256}, :address, :address, {:uint, 256}, {:uint, 256}, {:uint, 256}, :bytes])
      |> hash()

    %{
      migrated_withdrawal_hash: withdrawal_hash,
      migrated_message_hash: hash(data),
      migrated_msg_data: "0x" <> Base.encode16(data, case: :lower),
      migrated_gas_limit: gas_limit
    }
  end

  # The values the migration attached: the amount of an ETH or MNT withdrawal sent by the L2StandardBridge, whatever
  # its target (as op-chain-ops reads it), and nothing otherwise
  defp migrated_values(%{sender: sender, message: message}, %{l2_standard_bridge: sender}) do
    case message do
      <<@finalize_eth_withdrawal::binary, arguments::binary>> -> {0, native_amount(arguments)}
      <<@finalize_mantle_withdrawal::binary, arguments::binary>> -> {native_amount(arguments), 0}
      _ -> {0, 0}
    end
  end

  defp migrated_values(_sent_message, _bridges), do: {0, 0}

  defp native_amount(arguments) do
    case decode(arguments, @native_arguments) do
      [_from, _to, amount, _data] -> amount
      nil -> 0
    end
  end

  defp deposit_transfer(<<@finalize_deposit::binary, arguments::binary>>) do
    with [l1_token, l2_token, from, to, amount, _data] <- decode(arguments, @erc20_arguments) do
      case address_string(l2_token) do
        @bvm_eth -> native_transfer(:eth, from, to, amount)
        @legacy_mnt -> native_transfer(:mnt, from, to, amount)
        l2_token_address -> erc20_transfer(address_string(l1_token), l2_token_address, from, to, amount)
      end
    end
  end

  defp deposit_transfer(_message), do: nil

  defp withdrawal_transfer(<<@finalize_eth_withdrawal::binary, arguments::binary>>),
    do: native_withdrawal(:eth, arguments)

  defp withdrawal_transfer(<<@finalize_mantle_withdrawal::binary, arguments::binary>>),
    do: native_withdrawal(:mnt, arguments)

  defp withdrawal_transfer(<<@finalize_erc20_withdrawal::binary, arguments::binary>>) do
    with [l1_token, l2_token, from, to, amount, _data] <- decode(arguments, @erc20_arguments) do
      erc20_transfer(address_string(l1_token), address_string(l2_token), from, to, amount)
    end
  end

  defp withdrawal_transfer(_message), do: nil

  defp native_withdrawal(type, arguments) do
    with [from, to, amount, _data] <- decode(arguments, @native_arguments) do
      native_transfer(type, from, to, amount)
    end
  end

  defp native_transfer(type, from, to, amount) do
    %{
      transfer_type: type,
      transfer_from_address_hash: address_string(from),
      transfer_to_address_hash: address_string(to),
      transfer_amount: amount
    }
  end

  defp erc20_transfer(l1_token, l2_token, from, to, amount) do
    %{
      transfer_type: :erc20,
      transfer_from_address_hash: address_string(from),
      transfer_to_address_hash: address_string(to),
      l1_token_address_hash: l1_token,
      l2_token_address_hash: l2_token,
      transfer_amount: amount
    }
  end

  # A v1 message, with the bridge transfer it carries when there is one
  defp message(sent_message, transfer) do
    Map.merge(
      %{
        message_hash: v0_message_hash(sent_message),
        transfer_type: :message,
        transfer_from_address_hash: sent_message.sender,
        transfer_to_address_hash: sent_message.target,
        l1_token_address_hash: nil,
        l2_token_address_hash: nil,
        transfer_amount: nil
      },
      transfer || %{}
    )
  end

  # ABI decoding raises on truncated or malformed data, which a payload from an arbitrary sender can be
  defp decode(arguments, types) do
    ABI.TypeDecoder.decode_raw(arguments, types)
  rescue
    _ -> nil
  end

  defp hash(binary), do: "0x" <> Base.encode16(ExKeccak.hash_256(binary), case: :lower)

  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :mixed)

  defp address_string(<<_::binary-size(20)>> = address), do: "0x" <> Base.encode16(address, case: :lower)
end
