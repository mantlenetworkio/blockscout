defmodule Explorer.Chain.Optimism.BridgeMessage do
  @moduledoc """
    Decodes the bridge transfer a cross-domain message carries: its type, sender, recipient, tokens and amount.

    Only messages authenticated at both layers are decoded:

    - outer: a withdrawal's `MessagePassed` is sent by the L2CrossDomainMessenger to the L1CrossDomainMessenger, a
      deposit by the aliased L1CrossDomainMessenger to the L2CrossDomainMessenger, so the payload is `relayMessage`;
    - inner: the messenger-level sender and target are a known bridge pair, the standard bridges or the configured
      wstETH bridges. The messengers authenticate that sender; nothing authenticates the payload itself.

    Everything else is a `message`: between the messenger-level sender and target when the outer layer holds, between
    the outer event's addresses otherwise. Without both rules anyone could send a `finalizeBridgeERC20(... to = victim)`
    payload and plant a transfer in the victim's history.
  """

  import Bitwise

  alias Explorer.Chain.Hash
  alias Explorer.Chain.Optimism.MessageRelay

  @l2_standard_bridge_predeploy "0x4200000000000000000000000000000000000010"

  # `applyL1ToL2Alias` adds this offset to the address of an L1 contract that calls the portal
  @l1_to_l2_alias_offset 0x1111000000000000000000000000000000001111

  # relayMessage(uint256,address,address,uint256,uint256,uint256,bytes) (Mantle)
  @mantle_relay_message <<0xFF, 0x8D, 0xAF, 0x15>>
  # relayMessage(uint256,address,address,uint256,uint256,bytes) (OP Stack)
  @op_relay_message <<0xD7, 0x64, 0xAD, 0x0B>>

  # finalizeBridgeETH(address,address,uint256,bytes)
  @finalize_bridge_eth <<0x16, 0x35, 0xF5, 0xFD>>
  # finalizeBridgeMNT(address,address,uint256,bytes)
  @finalize_bridge_mnt <<0xF4, 0x07, 0xA9, 0x9E>>
  # finalizeBridgeERC20(address,address,address,address,uint256,bytes)
  @finalize_bridge_erc20 <<0x01, 0x66, 0xA0, 0x7A>>
  # finalizeERC20Withdrawal(address,address,address,address,uint256,bytes) of the L1WstBridge
  @finalize_erc20_withdrawal <<0xA9, 0xF9, 0xE6, 0x75>>
  # finalizeDeposit(address,address,address,address,uint256,bytes) of the L2WstBridge
  @finalize_deposit <<0x66, 0x2A, 0x63, 0x3A>>

  @mantle_relay_message_arguments [{:uint, 256}, :address, :address, {:uint, 256}, {:uint, 256}, {:uint, 256}, :bytes]
  @op_relay_message_arguments [{:uint, 256}, :address, :address, {:uint, 256}, {:uint, 256}, :bytes]
  @native_arguments [:address, :address, {:uint, 256}, :bytes]
  @erc20_arguments [:address, :address, :address, :address, {:uint, 256}, :bytes]

  @type bridges :: %{
          l1_cross_domain_messenger: String.t(),
          aliased_l1_cross_domain_messenger: String.t(),
          l2_cross_domain_messenger: String.t(),
          l1_standard_bridge: String.t(),
          l2_standard_bridge: String.t(),
          l1_wst_bridge: String.t() | nil,
          l2_wst_bridge: String.t() | nil
        }

  @typedoc "An outer message: the event's sender and target, the message data and the values the event carries."
  @type message :: %{
          from: String.t() | nil,
          to: String.t() | nil,
          data: binary(),
          mnt_value: non_neg_integer() | nil,
          eth_value: non_neg_integer() | nil
        }

  @type transfer :: %{
          message_hash: String.t() | nil,
          transfer_type: :eth | :mnt | :erc20 | :message,
          transfer_from_address_hash: String.t() | nil,
          transfer_to_address_hash: String.t() | nil,
          l1_token_address_hash: String.t() | nil,
          l2_token_address_hash: String.t() | nil,
          transfer_amount: non_neg_integer() | nil,
          mnt_value: non_neg_integer() | nil,
          eth_value: non_neg_integer() | nil
        }

  @doc """
    Returns the messenger and bridge addresses that decoding authenticates against, in lower case. Returns `nil` when
    the L1CrossDomainMessenger (INDEXER_OPTIMISM_L1_CROSS_DOMAIN_MESSENGER_CONTRACT) or the L1StandardBridge
    (INDEXER_OPTIMISM_L1_STANDARD_BRIDGE_CONTRACT) is missing: without them nothing can be authenticated.
  """
  @spec bridges() :: bridges() | nil
  def bridges do
    optimism = Application.get_env(:indexer, Indexer.Fetcher.Optimism, [])
    relay_l1 = Application.get_env(:indexer, Indexer.Fetcher.Optimism.MessageRelayL1, [])

    with l1_messenger when is_binary(l1_messenger) <- address(relay_l1[:l1_cross_domain_messenger]),
         l1_standard_bridge when is_binary(l1_standard_bridge) <- address(optimism[:l1_standard_bridge]) do
      %{
        l1_cross_domain_messenger: l1_messenger,
        aliased_l1_cross_domain_messenger: apply_l1_to_l2_alias(l1_messenger),
        l2_cross_domain_messenger: MessageRelay.l2_cross_domain_messenger(),
        l1_standard_bridge: l1_standard_bridge,
        l2_standard_bridge: address(optimism[:l2_standard_bridge]) || @l2_standard_bridge_predeploy,
        l1_wst_bridge: address(optimism[:l1_wst_bridge]),
        l2_wst_bridge: address(optimism[:l2_wst_bridge])
      }
    end
  end

  @doc """
    Decodes the transfer of a withdrawal from its `MessagePassed` event: `from` / `to` are the event's sender and
    target, `data` its message and the values the ones it carries. Returns `%{}` when `bridges` is `nil`.
  """
  @spec decode_withdrawal(message(), bridges() | nil) :: transfer() | %{}
  def decode_withdrawal(_message, nil), do: %{}

  def decode_withdrawal(message, bridges) do
    if same_address?(message.from, bridges.l2_cross_domain_messenger) and
         same_address?(message.to, bridges.l1_cross_domain_messenger) do
      decode_relay_message(message, :withdrawal, bridges)
    else
      outer_message(message)
    end
  end

  @doc """
    Decodes the transfer of a deposit from its `TransactionDeposited` event or its L2 transaction: `from` / `to` are
    the deposit's sender (aliased for contracts) and target, `data` its calldata and the values the ones it delivers.
    Returns `%{}` when `bridges` is `nil`.
  """
  @spec decode_deposit(message(), bridges() | nil) :: transfer() | %{}
  def decode_deposit(_message, nil), do: %{}

  def decode_deposit(message, bridges) do
    if same_address?(message.from, bridges.aliased_l1_cross_domain_messenger) and
         same_address?(message.to, bridges.l2_cross_domain_messenger) do
      decode_relay_message(message, :deposit, bridges)
    else
      outer_message(message)
    end
  end

  @doc "Returns the address in the last 20 bytes of a log topic, in lower case."
  @spec topic_to_address(Hash.t() | String.t() | nil) :: String.t() | nil
  def topic_to_address(nil), do: nil
  def topic_to_address(%Hash{} = topic), do: topic |> Hash.to_string() |> topic_to_address()
  def topic_to_address(topic) when is_binary(topic), do: "0x" <> String.downcase(String.slice(topic, -40, 40))

  @doc "Returns the L2 address that an L1 contract's portal calls come from (`AddressAliasHelper.applyL1ToL2Alias`)."
  @spec apply_l1_to_l2_alias(String.t()) :: String.t()
  def apply_l1_to_l2_alias("0x" <> hex) do
    <<address::160>> = Base.decode16!(hex, case: :mixed)
    aliased = address + @l1_to_l2_alias_offset &&& (1 <<< 160) - 1
    "0x" <> Base.encode16(<<aliased::160>>, case: :lower)
  end

  defp decode_relay_message(
         %{data: <<@mantle_relay_message::binary, arguments::binary>> = calldata} = message,
         direction,
         bridges
       ) do
    case decode(arguments, @mantle_relay_message_arguments) do
      [_nonce, sender, target, mnt_value, eth_value, _min_gas_limit, inner] ->
        sender_and_target = {address_string(sender), address_string(target)}
        relayed(calldata, sender_and_target, {mnt_value, eth_value}, inner, direction, bridges)

      nil ->
        outer_message(message)
    end
  end

  defp decode_relay_message(
         %{data: <<@op_relay_message::binary, arguments::binary>> = calldata} = message,
         direction,
         bridges
       ) do
    case decode(arguments, @op_relay_message_arguments) do
      [_nonce, sender, target, value, _min_gas_limit, inner] ->
        sender_and_target = {address_string(sender), address_string(target)}
        relayed(calldata, sender_and_target, {nil, value}, inner, direction, bridges)

      nil ->
        outer_message(message)
    end
  end

  defp decode_relay_message(message, _direction, _bridges), do: outer_message(message)

  # An authenticated messenger message: a transfer if a known bridge pair sent a known call, a message otherwise
  defp relayed(calldata, {sender, target}, {mnt_value, eth_value}, inner, direction, bridges) do
    message = %{
      transfer(:message, sender, target)
      | message_hash: calldata |> MessageRelay.message_hash() |> to_string(),
        mnt_value: mnt_value,
        eth_value: eth_value
    }

    case bridge_transfer(bridge_pair(sender, target, direction, bridges), inner, direction) do
      nil -> message
      transfer -> Map.merge(message, transfer)
    end
  end

  # The messenger-level sender and target as a known bridge pair, oriented by the direction of the message. Unset wst
  # bridges never match: the sender and target are always addresses.
  defp bridge_pair(sender, target, :withdrawal, bridges) do
    pair_kind(
      {sender, target},
      {bridges.l2_standard_bridge, bridges.l1_standard_bridge},
      {bridges.l2_wst_bridge, bridges.l1_wst_bridge}
    )
  end

  defp bridge_pair(sender, target, :deposit, bridges) do
    pair_kind(
      {sender, target},
      {bridges.l1_standard_bridge, bridges.l2_standard_bridge},
      {bridges.l1_wst_bridge, bridges.l2_wst_bridge}
    )
  end

  defp pair_kind(pair, standard, _wst) when pair == standard, do: :standard
  defp pair_kind(pair, _standard, wst) when pair == wst, do: :wst
  defp pair_kind(_pair, _standard, _wst), do: nil

  defp bridge_transfer(:standard, <<@finalize_bridge_eth::binary, arguments::binary>>, _direction),
    do: native_transfer(:eth, arguments)

  defp bridge_transfer(:standard, <<@finalize_bridge_mnt::binary, arguments::binary>>, _direction),
    do: native_transfer(:mnt, arguments)

  # `localToken` is the token on the chain the message is relayed to
  defp bridge_transfer(:standard, <<@finalize_bridge_erc20::binary, arguments::binary>>, direction) do
    with [local_token, remote_token, from, to, amount, _extra_data] <- decode(arguments, @erc20_arguments) do
      case direction do
        :withdrawal -> erc20_transfer(local_token, remote_token, from, to, amount)
        :deposit -> erc20_transfer(remote_token, local_token, from, to, amount)
      end
    end
  end

  defp bridge_transfer(:wst, <<@finalize_erc20_withdrawal::binary, arguments::binary>>, :withdrawal),
    do: explicit_erc20_transfer(arguments)

  defp bridge_transfer(:wst, <<@finalize_deposit::binary, arguments::binary>>, :deposit),
    do: explicit_erc20_transfer(arguments)

  defp bridge_transfer(_pair, _inner, _direction), do: nil

  defp native_transfer(type, arguments) do
    with [from, to, amount, _extra_data] <- decode(arguments, @native_arguments) do
      %{
        transfer_type: type,
        transfer_from_address_hash: address_string(from),
        transfer_to_address_hash: address_string(to),
        transfer_amount: amount
      }
    end
  end

  defp explicit_erc20_transfer(arguments) do
    with [l1_token, l2_token, from, to, amount, _data] <- decode(arguments, @erc20_arguments) do
      erc20_transfer(l1_token, l2_token, from, to, amount)
    end
  end

  defp erc20_transfer(l1_token, l2_token, from, to, amount) do
    %{
      transfer_type: :erc20,
      transfer_from_address_hash: address_string(from),
      transfer_to_address_hash: address_string(to),
      l1_token_address_hash: address_string(l1_token),
      l2_token_address_hash: address_string(l2_token),
      transfer_amount: amount
    }
  end

  defp outer_message(message) do
    %{
      transfer(:message, normalize(message.from), normalize(message.to))
      | mnt_value: message.mnt_value,
        eth_value: message.eth_value
    }
  end

  defp transfer(type, from, to) do
    %{
      message_hash: nil,
      transfer_type: type,
      transfer_from_address_hash: from,
      transfer_to_address_hash: to,
      l1_token_address_hash: nil,
      l2_token_address_hash: nil,
      transfer_amount: nil,
      mnt_value: nil,
      eth_value: nil
    }
  end

  # ABI decoding raises on truncated or malformed data, which a payload from an arbitrary sender can be
  defp decode(arguments, types) do
    ABI.TypeDecoder.decode_raw(arguments, types)
  rescue
    _ -> nil
  end

  defp address(value) when is_binary(value) do
    case Hash.Address.cast(value) do
      {:ok, hash} -> Hash.to_string(hash)
      :error -> nil
    end
  end

  defp address(_value), do: nil

  defp address_string(<<_::binary-size(20)>> = bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  defp normalize(nil), do: nil
  defp normalize(address), do: String.downcase(address)

  defp same_address?(address, expected) when is_binary(address), do: String.downcase(address) == expected
  defp same_address?(_address, _expected), do: false
end
