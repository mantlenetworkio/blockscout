defmodule Indexer.Fetcher.Optimism.LegacyBridge do
  @moduledoc """
    Rebuilds the Mantle v1 (pre-Bedrock) bridge history from chain data, once per network, and validates it against
    the chain before `Explorer.Chain.Optimism.BridgeHistory` serves it.

    It reads the events of the legacy cross-domain messengers over the fixed block ranges set with
    INDEXER_OPTIMISM_LEGACY_{L2,L1}_{START,END}_BLOCK:

    - on L2, `SentMessage` (v1 withdrawals) and the relay events (relays of v1 deposits);
    - on L1, `SentMessage` (v1 deposits) and the relay events (relays of withdrawals in the v1 era).

    v1 messages are told apart by their version 0 nonce, so a start block may come early. An end block must be the
    upgrade boundary itself: a relay event carries only a hash, so a v2 relay past the boundary cannot be told from a
    v1 one and fails the validation. Rows go to `mantle_legacy_bridge_transfers` and relays to `op_message_relays`
    under their v0 hashes. The last block written in each range is kept as a constant, so a restart resumes after it.

    It then validates the rows, and sets the `optimism_legacy_bridge_validated` constant to "true" only when:
    - both directions have rows, the withdrawal nonces run without a gap from the legacy messenger's first one, and
      the deposit nonces start at 0, so that a range the RPC answered without its logs shows;
    - every relay in the ranges matches a v1 message of the other side;
    - `L2ToL1MessagePasser.sentMessages` knows every migrated withdrawal hash.
    Otherwise it sets "false" and logs what failed. Both outcomes are final: the fetcher does not run again until an
    operator removes the constant. Removing it validates the stored rows again; removing the two progress constants
    (`optimism_legacy_bridge_l2_block`, `optimism_legacy_bridge_l1_block`) as well rebuilds them first.
  """

  use GenServer
  use Indexer.Fetcher

  require Logger

  import Ecto.Query
  import EthereumJSONRPC, only: [quantity_to_integer: 1]

  alias Explorer.Application.Constants
  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.Optimism.{BridgeMessage, LegacyBridgeMessage, LegacyBridgeTransfer, MessageRelay}
  alias Explorer.Helper, as: ExplorerHelper
  alias Indexer.Fetcher.Optimism
  alias Indexer.Helper

  @fetcher_name :optimism_legacy_bridge
  @l2_block_constant "optimism_legacy_bridge_l2_block"
  @l1_block_constant "optimism_legacy_bridge_l1_block"
  @message_passer "0x4200000000000000000000000000000000000016"
  # sentMessages(bytes32)
  @sent_messages_selector "0x82e3702d"
  @validation_batch_size 100
  @validation_page_size 1_000
  # Mantle's legacy L2CrossDomainMessenger numbered its messages one by one from 100,000, on mainnet and Sepolia alike
  @first_withdrawal_nonce 100_000
  @max_retry_pause_seconds 60

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(args) do
    {:ok, %{}, {:continue, Keyword.get(args, :json_rpc_named_arguments)}}
  end

  @impl GenServer
  def handle_continue(json_rpc_named_arguments, _state) do
    Logger.metadata(fetcher: @fetcher_name)

    bridges = BridgeMessage.bridges()

    cond do
      Constants.get_constant_value(LegacyBridgeTransfer.validated_constant()) in ["true", "false"] ->
        {:stop, :normal, %{}}

      is_nil(bridges) ->
        Logger.error(
          "The L1CrossDomainMessenger or L1StandardBridge address is not set, the v1 history is not rebuilt."
        )

        {:stop, :normal, %{}}

      true ->
        Process.send(self(), :continue, [])
        {:noreply, initial_state(bridges, json_rpc_named_arguments)}
    end
  end

  @impl GenServer
  def handle_info(:continue, %{phase: :l2} = state) do
    backfill(state.l2, state.bridges)
    Process.send(self(), :continue, [])
    {:noreply, %{state | phase: :l1}}
  end

  def handle_info(:continue, %{phase: :l1} = state) do
    backfill(state.l1, state.bridges)
    Process.send(self(), :continue, [])
    {:noreply, %{state | phase: :validate}}
  end

  def handle_info(:continue, %{phase: :validate} = state) do
    validate(state)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  defp initial_state(bridges, json_rpc_named_arguments) do
    env = Application.get_all_env(:indexer)[__MODULE__]
    optimism = Application.get_all_env(:indexer)[Optimism]

    l2_json_rpc_named_arguments =
      case env[:l2_rpc] do
        nil -> json_rpc_named_arguments
        "" -> json_rpc_named_arguments
        url -> legacy_l2_json_rpc_named_arguments(url)
      end

    %{
      phase: :l2,
      bridges: bridges,
      # sentMessages needs the current state only, which the indexer's own L2 node has
      validation_json_rpc_named_arguments: json_rpc_named_arguments,
      l2: %{
        direction: :withdrawal,
        chain: :l2,
        messenger: bridges.l2_cross_domain_messenger,
        start_block: env[:l2_start_block],
        end_block: env[:l2_end_block],
        range_size: env[:l2_eth_get_logs_range_size] || optimism[:l2_eth_get_logs_range_size],
        progress_constant: @l2_block_constant,
        json_rpc_named_arguments: l2_json_rpc_named_arguments
      },
      l1: %{
        direction: :deposit,
        chain: :l1,
        messenger: bridges.l1_cross_domain_messenger,
        start_block: env[:l1_start_block],
        end_block: env[:l1_end_block],
        range_size: optimism[:l1_eth_get_logs_range_size],
        progress_constant: @l1_block_constant,
        json_rpc_named_arguments: Helper.l1_json_rpc_named_arguments(Optimism.l1_rpc_url())
      }
    }
  end

  # The v1 era is read from an L2 node: its requests are not counted as requests to the parent chain
  defp legacy_l2_json_rpc_named_arguments(url) do
    url
    |> Helper.l1_json_rpc_named_arguments()
    |> update_in([:transport_options, :http_options], &Keyword.delete(&1, :layer))
  end

  # Writes the v1 messages and relays of one chain's range, chunk by chunk, after the last block already written
  defp backfill(%{start_block: start_block, end_block: end_block, range_size: range_size} = side, bridges) do
    first_block =
      case ExplorerHelper.parse_integer(Constants.get_constant_value(side.progress_constant)) do
        nil -> start_block
        last_written -> max(last_written + 1, start_block)
      end

    if first_block <= end_block do
      for chunk_start <- first_block..end_block//range_size do
        chunk_end = min(chunk_start + range_size - 1, end_block)
        Helper.log_blocks_chunk_handling(chunk_start, chunk_end, start_block, end_block, nil, side_name(side))
        handle_chunk(chunk_start, chunk_end, side, bridges)
      end
    end

    :ok
  end

  defp handle_chunk(chunk_start, chunk_end, side, bridges) do
    {:ok, logs} =
      Helper.get_logs(
        chunk_start,
        chunk_end,
        side.messenger,
        [[LegacyBridgeMessage.sent_message_event() | MessageRelay.relay_events()]],
        side.json_rpc_named_arguments,
        0,
        Helper.infinite_retries_number()
      )

    messages = for log <- logs, sent_message = LegacyBridgeMessage.sent_message(log), do: {log, sent_message}
    timestamps = block_timestamps(messages, side.json_rpc_named_arguments)
    rows = Enum.map(messages, fn {log, sent_message} -> row(side.direction, log, sent_message, timestamps, bridges) end)
    relays = MessageRelay.events_to_relays(logs, side.chain)

    # Both writes are idempotent and the progress is written last, so a chunk cut short is simply written again
    LegacyBridgeTransfer.upsert_all(rows)
    {:ok, _} = Chain.import(%{optimism_message_relays: %{params: relays}, timeout: :infinity})
    Constants.set_constant_value(side.progress_constant, Integer.to_string(chunk_end))

    Helper.log_blocks_chunk_handling(
      chunk_start,
      chunk_end,
      side.start_block,
      side.end_block,
      "#{length(rows)} v1 message(s), #{length(relays)} relay(s)",
      side_name(side)
    )
  end

  defp block_timestamps([], _json_rpc_named_arguments), do: %{}

  defp block_timestamps(messages, json_rpc_named_arguments) do
    messages
    |> Enum.map(fn {log, _sent_message} -> log end)
    |> Helper.get_blocks_by_events(json_rpc_named_arguments, Helper.infinite_retries_number())
    |> Map.new(fn block ->
      {:ok, timestamp} = DateTime.from_unix(quantity_to_integer(block["timestamp"]))
      {quantity_to_integer(block["number"]), timestamp}
    end)
  end

  defp row(direction, log, sent_message, timestamps, bridges) do
    block_number = quantity_to_integer(log["blockNumber"])

    decoded =
      case direction do
        :deposit -> LegacyBridgeMessage.decode_deposit(sent_message, bridges)
        :withdrawal -> LegacyBridgeMessage.decode_withdrawal(sent_message, bridges)
      end

    Map.merge(decoded, %{
      direction: direction,
      nonce: Decimal.new(sent_message.nonce),
      transaction_hash: log["transactionHash"],
      block_number: block_number,
      timestamp: Map.get(timestamps, block_number)
    })
  end

  defp side_name(%{chain: :l1}), do: :L1
  defp side_name(%{chain: :l2}), do: :L2

  # The rows are served only when they look complete, every relay of the ranges belongs to a v1 message, and every
  # migrated withdrawal hash is proven by the L2ToL1MessagePasser. The database checks come first: the RPC check, a
  # call per withdrawal, runs only when they pass.
  defp validate(state) do
    pending_deposits = deposits_without_relay()

    if pending_deposits > 0 do
      Logger.warning("#{pending_deposits} v1 deposit(s) have no L2 relay and show as Pending.")
    end

    errors =
      case completeness_errors() ++ relay_errors(state) do
        [] -> message_passer_errors(state.validation_json_rpc_named_arguments)
        errors -> errors
      end

    if errors == [] do
      Constants.set_constant_value(LegacyBridgeTransfer.validated_constant(), "true")
      Logger.info("The v1 bridge history is validated and served.")
    else
      Constants.set_constant_value(LegacyBridgeTransfer.validated_constant(), "false")

      Logger.error(
        "The v1 bridge history failed validation and is not served: #{Enum.join(errors, "; ")}. To rebuild it, " <>
          "remove the constants #{@l2_block_constant}, #{@l1_block_constant} and " <>
          "#{LegacyBridgeTransfer.validated_constant()}; to validate it again, remove the last one."
      )
    end
  end

  # Both networks with a v1 era have v1 messages both ways. Withdrawal nonces have no gap (the legacy L2 messenger
  # counted its messages), and the first legacy L1 message took queue index 0; later deposit nonces may skip, as the
  # queue also took direct enqueues. So a range the RPC answered without its logs shows.
  defp completeness_errors do
    withdrawal_errors(nonce_stats(:withdrawal)) ++ deposit_errors(nonce_stats(:deposit))
  end

  defp nonce_stats(direction) do
    from(t in LegacyBridgeTransfer,
      where: t.direction == ^direction,
      select: {count(), min(t.nonce), max(t.nonce)}
    )
    |> Repo.one(timeout: :infinity)
  end

  defp withdrawal_errors({0, _min, _max}), do: ["no v1 withdrawal was found (does the L2 RPC serve pre-Bedrock logs?)"]

  defp withdrawal_errors({count, min, max}) do
    if Decimal.equal?(min, @first_withdrawal_nonce) and Decimal.equal?(Decimal.sub(max, min), count - 1),
      do: [],
      else: [
        "#{count} v1 withdrawal nonce(s) span #{min}..#{max}, while the legacy L2 messenger numbered its messages " <>
          "one by one from #{@first_withdrawal_nonce}"
      ]
  end

  defp deposit_errors({0, _min, _max}), do: ["no v1 deposit was found (does the L1 RPC serve the range's logs?)"]

  defp deposit_errors({_count, min, _max}) do
    if Decimal.equal?(min, 0), do: [], else: ["the v1 deposit nonces start at #{min}, not 0"]
  end

  # A relay of the ranges that matches no v1 message. Their blocks tell an end block past the upgrade (v2 relays) from
  # a wrong v0 hash.
  defp relay_errors(state) do
    for {side, direction, name} <- [{state.l2, :deposit, "L2"}, {state.l1, :withdrawal, "L1"}],
        {count, first_block, last_block} = unmatched_relays(side, direction),
        count > 0 do
      "unmatched relay(s): #{count} on #{name} (blocks #{first_block}..#{last_block})"
    end
  end

  defp message_passer_errors(json_rpc_named_arguments) do
    case withdrawals_unknown_to_message_passer(json_rpc_named_arguments) do
      [] ->
        []

      nonces ->
        [
          "#{length(nonces)} withdrawal(s) whose migrated hash sentMessages does not know (nonces, first 100): " <>
            inspect(Enum.take(nonces, 100))
        ]
    end
  end

  # Asks L2ToL1MessagePasser.sentMessages for every migrated withdrawal hash, a page of rows at a time, and returns the
  # nonces it answers false for. An RPC error is asked again until it answers: an error is never a result.
  defp withdrawals_unknown_to_message_passer(json_rpc_named_arguments, after_nonce \\ nil, acc \\ []) do
    page =
      from(t in LegacyBridgeTransfer,
        where: t.direction == :withdrawal,
        order_by: t.nonce,
        select: {t.nonce, t.migrated_withdrawal_hash},
        limit: @validation_page_size
      )
      |> after_nonce(after_nonce)
      |> Repo.all(timeout: :infinity)

    case page do
      [] ->
        Enum.reverse(acc)

      _ ->
        unknown =
          page
          |> Enum.chunk_every(@validation_batch_size)
          |> Enum.flat_map(&unknown_in_batch(&1, json_rpc_named_arguments))

        {last_nonce, _} = List.last(page)
        withdrawals_unknown_to_message_passer(json_rpc_named_arguments, last_nonce, Enum.reverse(unknown) ++ acc)
    end
  end

  defp after_nonce(query, nil), do: query
  defp after_nonce(query, nonce), do: from(t in query, where: t.nonce > ^nonce)

  defp unknown_in_batch(batch, json_rpc_named_arguments) do
    answers = sent_messages(batch, json_rpc_named_arguments, %{})
    for {nonce, _hash} <- batch, answers[nonce] == false, do: Decimal.to_string(nonce)
  end

  # Returns `nonce => true | false` for every row of the batch, asking again, with a growing pause and a log line, for
  # the ones without a definite answer: an error, or anything but a 32-byte word (a call to an address without code
  # answers "0x")
  defp sent_messages(rows, json_rpc_named_arguments, answers, attempt \\ 0)

  defp sent_messages([], _json_rpc_named_arguments, answers, _attempt), do: answers

  defp sent_messages(rows, json_rpc_named_arguments, answers, attempt) do
    requests =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {{_nonce, hash}, id} ->
        EthereumJSONRPC.request(%{
          id: id,
          method: "eth_call",
          params: [
            %{to: @message_passer, data: @sent_messages_selector <> String.trim_leading(to_string(hash), "0x")},
            "latest"
          ]
        })
      end)

    {results, batch_error} =
      case EthereumJSONRPC.json_rpc(requests, json_rpc_named_arguments) do
        {:ok, responses} -> {Map.new(responses, &{&1.id, &1}), nil}
        {:error, reason} -> {%{}, reason}
      end

    {answered, unanswered} =
      rows
      |> Enum.with_index()
      |> Enum.split_with(fn {_row, id} -> word?(results[id]) end)

    answers =
      Enum.reduce(answered, answers, fn {{nonce, _hash}, id}, acc ->
        Map.put(acc, nonce, quantity_to_integer(results[id].result) == 1)
      end)

    if unanswered != [] do
      [{_row, id} | _] = unanswered
      pause = min(Integer.pow(2, attempt), @max_retry_pause_seconds)

      Logger.warning(
        "sentMessages: #{length(unanswered)} of #{length(rows)} call(s) got no answer (first: " <>
          "#{inspect(batch_error || results[id])}). Asking again in #{pause} s."
      )

      :timer.sleep(:timer.seconds(pause))
    end

    sent_messages(Enum.map(unanswered, &elem(&1, 0)), json_rpc_named_arguments, answers, attempt + 1)
  end

  defp word?(%{result: "0x" <> word}), do: byte_size(word) == 64
  defp word?(_response), do: false

  # The count and the first and last blocks of the relays of the range whose hash is the v0 hash of no v1 message of
  # the given direction
  defp unmatched_relays(%{chain: chain, start_block: start_block, end_block: end_block}, direction) do
    from(r in MessageRelay,
      as: :relay,
      where: r.chain == ^chain and r.block_number >= ^start_block and r.block_number <= ^end_block,
      where:
        not exists(
          from(t in LegacyBridgeTransfer,
            where: t.direction == ^direction and t.message_hash == parent_as(:relay).message_hash,
            select: 1
          )
        ),
      select: {count(), min(r.block_number), max(r.block_number)}
    )
    |> Repo.one(timeout: :infinity)
  end

  defp deposits_without_relay do
    from(t in LegacyBridgeTransfer,
      as: :deposit,
      where: t.direction == :deposit,
      where:
        not exists(
          from(r in MessageRelay,
            where: r.chain == :l2 and r.message_hash == parent_as(:deposit).message_hash,
            select: 1
          )
        )
    )
    |> Repo.aggregate(:count, timeout: :infinity)
  end
end
