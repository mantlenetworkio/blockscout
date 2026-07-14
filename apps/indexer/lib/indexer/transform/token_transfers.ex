defmodule Indexer.Transform.TokenTransfers do
  @moduledoc """
  Helper functions for transforming data for known token standards (ERC-20, ERC-721, ERC-1155, ERC-404, ERC-7984) transfers.
  """

  require Logger

  use Utils.RuntimeEnvHelper,
    chain_type: [:explorer, :chain_type],
    arc_native_token_address: [:indexer, [:arc, :arc_native_token_address]],
    arc_native_token_system_address: [:indexer, [:arc, :arc_native_token_system_address]],
    arc_native_token_decimals: [:indexer, [:arc, :arc_native_token_decimals]]

  import Explorer.Chain.SmartContract, only: [burn_address_hash_string: 0]
  import Explorer.Helper, only: [decode_data: 2, truncate_address_hash: 1]

  alias Explorer.Chain.ScaledUi.Events
  alias Explorer.Chain.{Hash, Token, TokenTransfer}
  alias Explorer.Repo
  alias Indexer.Fetcher.TokenTotalSupplyUpdater

  @doc """
  Returns a list of token transfers given a list of logs.
  """
  def parse(logs, skip_additional_fetchers? \\ false) do
    initial_acc = %{tokens: [], token_transfers: []}

    erc20_and_erc721_token_transfers_filtered =
      if chain_type() == :arc do
        allowed_erc20_erc721_token_transfer_events =
          [
            TokenTransfer.constant(),
            TokenTransfer.arc_native_coin_transferred_event(),
            TokenTransfer.arc_native_coin_minted_event(),
            TokenTransfer.arc_native_coin_burned_event()
          ]

        Enum.filter(logs, &(&1.first_topic in allowed_erc20_erc721_token_transfer_events))
      else
        Enum.filter(logs, &(&1.first_topic == unquote(TokenTransfer.constant())))
      end

    erc20_and_erc721_token_transfers =
      erc20_and_erc721_token_transfers_filtered
      |> Enum.reduce(initial_acc, &do_parse/2)

    weth_transfers =
      logs
      |> Enum.filter(fn log ->
        (log.first_topic == TokenTransfer.weth_deposit_signature() ||
           log.first_topic == TokenTransfer.weth_withdrawal_signature()) &&
          TokenTransfer.whitelisted_weth_contract?(log.address_hash)
      end)
      |> Enum.reduce(initial_acc, &do_parse/2)
      |> drop_repeated_token_transfers(erc20_and_erc721_token_transfers.token_transfers)

    erc1155_token_transfers =
      logs
      |> Enum.filter(fn log ->
        log.first_topic == TokenTransfer.erc1155_single_transfer_signature() ||
          log.first_topic == TokenTransfer.erc1155_batch_transfer_signature()
      end)
      |> Enum.reduce(initial_acc, &do_parse(&1, &2, :erc1155))

    erc404_token_transfers =
      logs
      |> Enum.filter(fn log ->
        log.first_topic == TokenTransfer.erc404_erc20_transfer_event() ||
          log.first_topic == TokenTransfer.erc404_erc721_transfer_event()
      end)
      |> Enum.reduce(initial_acc, &do_parse(&1, &2, :erc404))

    erc7984_token_transfers =
      logs
      |> Enum.filter(fn log ->
        log.first_topic == TokenTransfer.erc7984_transfer_event()
      end)
      |> Enum.reduce(initial_acc, &do_parse(&1, &2, :erc7984))

    rough_tokens =
      erc7984_token_transfers.tokens ++
        erc404_token_transfers.tokens ++
        erc1155_token_transfers.tokens ++
        erc20_and_erc721_token_transfers.tokens ++ weth_transfers.tokens

    rough_token_transfers =
      erc7984_token_transfers.token_transfers ++
        erc404_token_transfers.token_transfers ++
        erc1155_token_transfers.token_transfers ++
        erc20_and_erc721_token_transfers.token_transfers ++ weth_transfers.token_transfers

    tokens = sanitize_token_types(rough_tokens, rough_token_transfers)

    token_transfers =
      tokens
      |> sanitize_weth_transfers(rough_token_transfers, weth_transfers.token_transfers)
      |> pair_scaled_ui_events(logs)

    if !skip_additional_fetchers? do
      token_transfers
      |> filter_tokens_for_supply_update()
      |> TokenTotalSupplyUpdater.add_tokens()
    end

    tokens_uniq = tokens |> Enum.uniq()

    token_transfers_from_logs_uniq = %{
      tokens: tokens_uniq,
      token_transfers: token_transfers
    }

    token_transfers_from_logs_uniq
  end

  defp pair_scaled_ui_events(token_transfers, logs) do
    ui_events =
      logs
      |> Enum.filter(&(&1.first_topic == Events.transfer_with_ui_amount_topic()))
      |> Enum.flat_map(&parse_scaled_ui_event/1)

    transfers_by_group =
      token_transfers
      |> Enum.filter(&(&1.token_type == "ERC-20"))
      |> Enum.group_by(&scaled_ui_group_key/1)

    ui_events_by_group = Enum.group_by(ui_events, &scaled_ui_group_key/1)

    matches =
      Enum.reduce(transfers_by_group, %{}, fn {group_key, transfers}, matches ->
        group_matches = match_scaled_ui_group(transfers, Map.get(ui_events_by_group, group_key, []))
        Map.merge(matches, group_matches)
      end)

    orphan_count = length(ui_events) - map_size(matches)

    if orphan_count > 0 do
      :telemetry.execute([:indexer, :scaled_ui, :orphan_ui_event], %{count: orphan_count}, %{})
    end

    Enum.map(token_transfers, fn transfer ->
      case Map.fetch(matches, token_transfer_to_key(transfer)) do
        {:ok, ui_value} -> Map.put(transfer, :ui_value, ui_value)
        :error -> transfer
      end
    end)
  end

  defp parse_scaled_ui_event(log) do
    [amount, ui_value] = decode_data(log.data, [{:uint, 256}, {:uint, 256}])

    [
      %{
        amount: Decimal.new(amount),
        block_hash: log.block_hash,
        from_address_hash: truncate_address_hash(log.second_topic),
        log_index: log.index,
        to_address_hash: truncate_address_hash(log.third_topic),
        token_contract_address_hash: log.address_hash,
        transaction_hash: log.transaction_hash,
        ui_value: Decimal.new(ui_value)
      }
    ]
  rescue
    error in [FunctionClauseError, MatchError] ->
      Logger.error(fn ->
        ["Unknown TransferWithUIAmount format: #{inspect(log)}", Exception.format(:error, error, __STACKTRACE__)]
      end)

      []
  end

  defp match_scaled_ui_group(transfers, ui_events) do
    transfers = Enum.sort_by(transfers, & &1.log_index)
    ui_events = Enum.sort_by(ui_events, & &1.log_index)

    {adjacent_matches, unmatched_transfers, remaining_ui_events} =
      match_scaled_ui_events(transfers, ui_events, %{}, &adjacent_scaled_ui_event?/2)

    {matches, _unmatched_transfers, _remaining_ui_events} =
      match_scaled_ui_events(unmatched_transfers, remaining_ui_events, adjacent_matches, &scaled_ui_content_matches?/2)

    matches
  end

  defp match_scaled_ui_events(transfers, ui_events, matches, matcher) do
    Enum.reduce(transfers, {matches, [], ui_events}, fn transfer, {matches, unmatched, ui_events} ->
      case take_first_match(ui_events, &matcher.(transfer, &1)) do
        {nil, ui_events} ->
          {matches, [transfer | unmatched], ui_events}

        {ui_event, ui_events} ->
          {Map.put(matches, token_transfer_to_key(transfer), ui_event.ui_value), unmatched, ui_events}
      end
    end)
    |> then(fn {matches, unmatched, ui_events} -> {matches, Enum.reverse(unmatched), ui_events} end)
  end

  defp take_first_match(events, matcher) do
    case Enum.split_while(events, &(not matcher.(&1))) do
      {before, [event | after_events]} -> {event, before ++ after_events}
      {_before, []} -> {nil, events}
    end
  end

  defp adjacent_scaled_ui_event?(transfer, ui_event) do
    abs(transfer.log_index - ui_event.log_index) == 1 and scaled_ui_content_matches?(transfer, ui_event)
  end

  defp scaled_ui_content_matches?(transfer, ui_event) do
    transfer.from_address_hash == ui_event.from_address_hash and
      transfer.to_address_hash == ui_event.to_address_hash and
      Decimal.equal?(transfer.amount, ui_event.amount)
  end

  defp scaled_ui_group_key(event) do
    {event.block_hash, event.transaction_hash, event.token_contract_address_hash}
  end

  defp drop_repeated_token_transfers(weth_acc, erc_20_721_token_transfers) do
    key_from_tt = fn tt ->
      {tt.block_hash, tt.transaction_hash, tt.token_contract_address_hash, tt.to_address_hash, tt.from_address_hash,
       tt.amount}
    end

    deposit_withdrawal_like_transfers =
      Enum.reduce(erc_20_721_token_transfers, %{}, fn token_transfer, acc ->
        if token_transfer.token_type == "ERC-20" and
             (token_transfer.from_address_hash == burn_address_hash_string() or
                token_transfer.to_address_hash == burn_address_hash_string()) do
          Map.put(acc, key_from_tt.(token_transfer), true)
        else
          acc
        end
      end)

    %{token_transfers: weth_token_transfer} = weth_acc

    weth_token_transfer_updated =
      Enum.reject(weth_token_transfer, fn weth_tt ->
        deposit_withdrawal_like_transfers[key_from_tt.(weth_tt)]
      end)

    Map.put(weth_acc, :token_transfers, weth_token_transfer_updated)
  end

  defp sanitize_weth_transfers(total_tokens, total_transfers, weth_transfers) do
    existing_token_types_map =
      total_tokens
      |> Enum.map(&{&1.contract_address_hash, &1.type})
      |> Map.new()

    invalid_weth_transfers =
      Enum.reduce(weth_transfers, %{}, fn token_transfer, acc ->
        if existing_token_types_map[token_transfer.token_contract_address_hash] == "ERC-721" do
          Map.put(acc, token_transfer_to_key(token_transfer), true)
        else
          acc
        end
      end)

    total_transfers
    |> subtract_token_transfers(invalid_weth_transfers)
    |> Enum.reverse()
  end

  defp token_transfer_to_key(token_transfer) do
    {token_transfer.block_hash, token_transfer.transaction_hash, token_transfer.log_index}
  end

  defp subtract_token_transfers(tt_from, tt_to_subtract) do
    Enum.reduce(tt_from, [], fn tt, acc ->
      case tt_to_subtract[token_transfer_to_key(tt)] do
        nil -> [tt | acc]
        _ -> acc
      end
    end)
  end

  defp sanitize_token_types(tokens, token_transfers) do
    existing_token_types_map =
      tokens
      |> Enum.uniq()
      |> Enum.reduce([], fn %{contract_address_hash: address_hash}, acc ->
        case Repo.get_by(Token, contract_address_hash: address_hash) do
          %{type: type} -> [{address_hash, type} | acc]
          _ -> acc
        end
      end)
      |> Map.new()

    token_types_map =
      token_transfers
      |> Enum.group_by(& &1.token_contract_address_hash)
      |> Enum.map(fn {contract_address_hash, transfers} ->
        {contract_address_hash, define_token_type(transfers)}
      end)
      |> Map.new()

    actual_token_types_map =
      Map.merge(token_types_map, existing_token_types_map, fn _k, new_type, old_type ->
        if token_type_priority(old_type) > token_type_priority(new_type), do: old_type, else: new_type
      end)

    Enum.map(tokens, fn %{contract_address_hash: hash} = token ->
      Map.put(token, :type, actual_token_types_map[hash])
    end)
  end

  defp define_token_type(token_transfers) do
    Enum.reduce(token_transfers, nil, fn %{token_type: token_type}, acc ->
      if token_type_priority(token_type) > token_type_priority(acc), do: token_type, else: acc
    end)
  end

  defp token_type_priority(nil), do: -1

  @token_types_priority_order ["ERC-20", "ERC-721", "ERC-1155", "ERC-404", "ERC-7984"]
  defp token_type_priority(token_type) do
    Enum.find_index(@token_types_priority_order, &(&1 == token_type))
  end

  defp do_parse(log, %{tokens: tokens, token_transfers: token_transfers} = acc, type \\ :erc20_erc721) do
    parse_result =
      case type do
        :erc1155 -> parse_erc1155_params(log)
        :erc404 -> parse_erc404_params(log)
        :erc7984 -> parse_erc7984_params(log)
        _ -> parse_params(log)
      end

    case parse_result do
      {token, token_transfer} ->
        %{
          tokens: [token | tokens],
          token_transfers: [token_transfer | token_transfers]
        }

      nil ->
        acc
    end
  rescue
    e in [FunctionClauseError, MatchError] ->
      Logger.error(fn ->
        ["Unknown token transfer format: #{inspect(log)}", Exception.format(:error, e, __STACKTRACE__)]
      end)

      acc
  end

  # ERC-20 token transfer
  defp parse_params(%{second_topic: second_topic, third_topic: third_topic, fourth_topic: nil} = log)
       when not is_nil(second_topic) and not is_nil(third_topic) do
    if arc_native_token_transfer_event?(log) do
      # for :arc chain type we need to ignore ERC-20 Transfer events from the native token as there are
      # NativeCoinTransferred, NativeCoinMinted, NativeCoinBurned events instead
      nil
    else
      # handle the transfer for other cases
      [decoded_amount] = decode_data(log.data, [{:uint, 256}])
      decimal_amount = Decimal.new(decoded_amount || 0)

      {token_contract_address_hash, amount} =
        if arc_native_coin_transferred_event?(log) do
          # if this is NativeCoinTransferred event for Arc chain, there are 18 decimals for the native token, so we need to adjust the amount with the token decimals
          {arc_native_token_address(), amount_18_decimals_to_n_decimals(decimal_amount, arc_native_token_decimals())}
        else
          {log.address_hash, decimal_amount}
        end

      token_transfer = %{
        amount: amount,
        block_number: log.block_number,
        block_hash: log.block_hash,
        log_index: log.index,
        from_address_hash: truncate_address_hash(log.second_topic),
        to_address_hash: truncate_address_hash(log.third_topic),
        token_contract_address_hash: token_contract_address_hash,
        transaction_hash: log.transaction_hash,
        token_ids: nil,
        token_type: "ERC-20"
      }

      token = %{
        contract_address_hash: token_contract_address_hash,
        type: "ERC-20"
      }

      {token, token_transfer}
    end
  end

  # ERC-20 token transfer for WETH or Arc native token mint/burn
  defp parse_params(%{second_topic: second_topic, third_topic: nil, fourth_topic: nil} = log)
       when not is_nil(second_topic) do
    [decoded_amount] = decode_data(log.data, [{:uint, 256}])
    decimal_amount = Decimal.new(decoded_amount || 0)

    {from_address_hash, to_address_hash, token_contract_address_hash, amount} =
      cond do
        log.first_topic == TokenTransfer.weth_deposit_signature() ->
          {burn_address_hash_string(), truncate_address_hash(log.second_topic), log.address_hash, decimal_amount}

        arc_native_coin_minted_event?(log) ->
          # there are 18 decimals for the native token, so we need to adjust the amount with the token decimals
          normalized_amount = amount_18_decimals_to_n_decimals(decimal_amount, arc_native_token_decimals())

          {burn_address_hash_string(), truncate_address_hash(log.second_topic), arc_native_token_address(),
           normalized_amount}

        arc_native_coin_burned_event?(log) ->
          # there are 18 decimals for the native token, so we need to adjust the amount with the token decimals
          normalized_amount = amount_18_decimals_to_n_decimals(decimal_amount, arc_native_token_decimals())

          {truncate_address_hash(log.second_topic), burn_address_hash_string(), arc_native_token_address(),
           normalized_amount}

        true ->
          {truncate_address_hash(log.second_topic), burn_address_hash_string(), log.address_hash, decimal_amount}
      end

    token_transfer = %{
      amount: amount,
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: from_address_hash,
      to_address_hash: to_address_hash,
      token_contract_address_hash: token_contract_address_hash,
      transaction_hash: log.transaction_hash,
      token_ids: nil,
      token_type: "ERC-20"
    }

    token = %{
      contract_address_hash: token_contract_address_hash,
      type: "ERC-20"
    }

    {token, token_transfer}
  end

  # ERC-721 token transfer with topics as addresses
  defp parse_params(%{second_topic: second_topic, third_topic: third_topic, fourth_topic: fourth_topic} = log)
       when not is_nil(second_topic) and not is_nil(third_topic) and not is_nil(fourth_topic) do
    [token_id] = decode_data(fourth_topic, [{:uint, 256}])

    from_address_hash = truncate_address_hash(log.second_topic)
    to_address_hash = truncate_address_hash(log.third_topic)

    token_transfer = %{
      block_number: log.block_number,
      log_index: log.index,
      block_hash: log.block_hash,
      from_address_hash: from_address_hash,
      to_address_hash: to_address_hash,
      token_contract_address_hash: log.address_hash,
      token_ids: [token_id || 0],
      transaction_hash: log.transaction_hash,
      token_type: "ERC-721"
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-721"
    }

    {token, token_transfer}
  end

  # ERC-721 token transfer with info in data field instead of in log topics
  defp parse_params(
         %{
           second_topic: nil,
           third_topic: nil,
           fourth_topic: nil,
           data: data
         } = log
       )
       when not is_nil(data) do
    [from_address_hash, to_address_hash, token_id] = decode_data(data, [:address, :address, {:uint, 256}])

    token_transfer = %{
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: "0x" <> Base.encode16(from_address_hash, case: :lower),
      to_address_hash: "0x" <> Base.encode16(to_address_hash, case: :lower),
      token_contract_address_hash: log.address_hash,
      token_ids: [token_id],
      transaction_hash: log.transaction_hash,
      token_type: "ERC-721"
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-721"
    }

    {token, token_transfer}
  end

  @spec parse_erc1155_params(map()) ::
          nil
          | {%{
               contract_address_hash: Hash.Address.t(),
               type: String.t()
             }, map()}
  defp parse_erc1155_params(
         %{
           first_topic: unquote(TokenTransfer.erc1155_batch_transfer_signature()),
           third_topic: third_topic,
           fourth_topic: fourth_topic,
           data: data
         } = log
       ) do
    [token_ids, values] = decode_data(data, [{:array, {:uint, 256}}, {:array, {:uint, 256}}])

    if is_nil(token_ids) or token_ids == [] or is_nil(values) or values == [] do
      nil
    else
      from_address_hash = truncate_address_hash(third_topic)
      to_address_hash = truncate_address_hash(fourth_topic)

      token_transfer = %{
        block_number: log.block_number,
        block_hash: log.block_hash,
        log_index: log.index,
        from_address_hash: from_address_hash,
        to_address_hash: to_address_hash,
        token_contract_address_hash: log.address_hash,
        transaction_hash: log.transaction_hash,
        token_type: "ERC-1155",
        token_ids: token_ids,
        amounts: values
      }

      token = %{
        contract_address_hash: log.address_hash,
        type: "ERC-1155"
      }

      {token, token_transfer}
    end
  end

  defp parse_erc1155_params(%{third_topic: third_topic, fourth_topic: fourth_topic, data: data} = log) do
    [token_id, value] = decode_data(data, [{:uint, 256}, {:uint, 256}])

    from_address_hash = truncate_address_hash(third_topic)
    to_address_hash = truncate_address_hash(fourth_topic)

    token_transfer = %{
      amount: value,
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: from_address_hash,
      to_address_hash: to_address_hash,
      token_contract_address_hash: log.address_hash,
      transaction_hash: log.transaction_hash,
      token_type: "ERC-1155",
      token_ids: [token_id]
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-1155"
    }

    {token, token_transfer}
  end

  @spec parse_erc404_params(map()) ::
          nil
          | {%{
               contract_address_hash: Hash.Address.t(),
               type: String.t()
             }, map()}
  defp parse_erc404_params(
         %{
           first_topic: unquote(TokenTransfer.erc404_erc20_transfer_event()),
           second_topic: second_topic,
           third_topic: third_topic,
           fourth_topic: nil,
           data: data
         } = log
       ) do
    [value] = decode_data(data, [{:uint, 256}])

    if is_nil(value) or value == [] do
      nil
    else
      token_transfer = %{
        block_number: log.block_number,
        block_hash: log.block_hash,
        log_index: log.index,
        from_address_hash: truncate_address_hash(second_topic),
        to_address_hash: truncate_address_hash(third_topic),
        token_contract_address_hash: log.address_hash,
        transaction_hash: log.transaction_hash,
        token_type: "ERC-404",
        token_ids: [],
        amounts: [value]
      }

      token = %{
        contract_address_hash: log.address_hash,
        type: "ERC-404"
      }

      {token, token_transfer}
    end
  end

  defp parse_erc404_params(
         %{
           first_topic: unquote(TokenTransfer.erc404_erc721_transfer_event()),
           second_topic: second_topic,
           third_topic: third_topic,
           fourth_topic: fourth_topic,
           data: _data
         } = log
       ) do
    [token_id] = decode_data(fourth_topic, [{:uint, 256}])

    if is_nil(token_id) or token_id == [] do
      nil
    else
      token_transfer = %{
        block_number: log.block_number,
        block_hash: log.block_hash,
        log_index: log.index,
        from_address_hash: truncate_address_hash(second_topic),
        to_address_hash: truncate_address_hash(third_topic),
        token_contract_address_hash: log.address_hash,
        transaction_hash: log.transaction_hash,
        token_type: "ERC-404",
        token_ids: [token_id],
        amounts: []
      }

      token = %{
        contract_address_hash: log.address_hash,
        type: "ERC-404"
      }

      {token, token_transfer}
    end
  end

  # Converts from 18-decimal amount to n-decimal amount.
  #
  # ## Parameters
  # - `amount`: The given 18-decimal amount to convert from.
  # - `new_decimals`: The new number of decimals.
  #
  # ## Returns
  # - The converted amount. If the source amount has more than `new_decimals` decimals, the new amount will be truncated.
  #   Example: If we have 18-decimal amount 25148712000000000, that will be 25148 for 6-decimal representation.
  @spec amount_18_decimals_to_n_decimals(Decimal.t(), non_neg_integer()) :: Decimal.t()
  defp amount_18_decimals_to_n_decimals(amount, new_decimals) do
    amount
    |> Decimal.mult(Integer.pow(10, new_decimals))
    |> Decimal.div_int(Integer.pow(10, 18))
  end

  # Determines if the given log is the NativeCoinTransferred event emitted by the native token system address on Arc chain.
  #
  # ## Parameters
  # - `log`: The log to check.
  #
  # ## Returns
  # - `true` if this is the NativeCoinTransferred event from the native token system address on Arc chain, `false` otherwise.
  @spec arc_native_coin_transferred_event?(%{
          :first_topic => String.t(),
          :address_hash => String.t(),
          optional(any()) => any()
        }) :: boolean()
  defp arc_native_coin_transferred_event?(log) do
    chain_type() == :arc and log.first_topic == TokenTransfer.arc_native_coin_transferred_event() and
      log.address_hash == arc_native_token_system_address()
  end

  # Determines if the given log is the NativeCoinMinted event emitted by the native token system address on Arc chain.
  #
  # ## Parameters
  # - `log`: The log to check.
  #
  # ## Returns
  # - `true` if this is the NativeCoinMinted event from the native token system address on Arc chain, `false` otherwise.
  @spec arc_native_coin_minted_event?(%{
          :first_topic => String.t(),
          :address_hash => String.t(),
          optional(any()) => any()
        }) :: boolean()
  defp arc_native_coin_minted_event?(log) do
    chain_type() == :arc and log.first_topic == TokenTransfer.arc_native_coin_minted_event() and
      log.address_hash == arc_native_token_system_address()
  end

  # Determines if the given log is the NativeCoinBurned event emitted by the native token system address on Arc chain.
  #
  # ## Parameters
  # - `log`: The log to check.
  #
  # ## Returns
  # - `true` if this is the NativeCoinBurned event from the native token system address on Arc chain, `false` otherwise.
  @spec arc_native_coin_burned_event?(%{
          :first_topic => String.t(),
          :address_hash => String.t(),
          optional(any()) => any()
        }) :: boolean()
  defp arc_native_coin_burned_event?(log) do
    chain_type() == :arc and log.first_topic == TokenTransfer.arc_native_coin_burned_event() and
      log.address_hash == arc_native_token_system_address()
  end

  # Determines if the given log is the Transfer event emitted by the native token contract on Arc chain.
  #
  # ## Parameters
  # - `log`: The log to check.
  #
  # ## Returns
  # - `true` if this is the Transfer event from the native token contract on Arc chain, `false` otherwise.
  @spec arc_native_token_transfer_event?(%{
          :first_topic => String.t(),
          :address_hash => String.t(),
          optional(any()) => any()
        }) :: boolean()
  defp arc_native_token_transfer_event?(log) do
    chain_type() == :arc and log.first_topic == TokenTransfer.constant() and
      log.address_hash == arc_native_token_address()
  end

  @spec parse_erc7984_params(map()) ::
          nil
          | {%{
               contract_address_hash: Hash.Address.t(),
               type: String.t()
             }, map()}
  defp parse_erc7984_params(
         %{
           second_topic: second_topic,
           third_topic: third_topic,
           fourth_topic: fourth_topic
         } = log
       )
       when not is_nil(second_topic) and not is_nil(third_topic) and not is_nil(fourth_topic) do
    from_address_hash = truncate_address_hash(second_topic)
    to_address_hash = truncate_address_hash(third_topic)

    token_transfer = %{
      block_number: log.block_number,
      block_hash: log.block_hash,
      log_index: log.index,
      from_address_hash: from_address_hash,
      to_address_hash: to_address_hash,
      token_contract_address_hash: log.address_hash,
      transaction_hash: log.transaction_hash,
      token_type: "ERC-7984",
      token_ids: nil,
      amount: nil
    }

    token = %{
      contract_address_hash: log.address_hash,
      type: "ERC-7984"
    }

    {token, token_transfer}
  end

  def filter_tokens_for_supply_update(token_transfers) do
    token_transfers
    |> Enum.filter(fn token_transfer ->
      token_transfer.to_address_hash == burn_address_hash_string() ||
        token_transfer.from_address_hash == burn_address_hash_string()
    end)
    |> Enum.map(& &1.token_contract_address_hash)
    |> Enum.uniq()
  end
end
