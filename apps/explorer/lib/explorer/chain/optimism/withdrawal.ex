defmodule Explorer.Chain.Optimism.Withdrawal do
  @moduledoc "Models Optimism withdrawal."

  use Explorer.Schema

  import Explorer.Chain, only: [default_paging_options: 0, select_repo: 1]

  alias Explorer.Application.Constants
  alias Explorer.Chain
  alias Explorer.Chain.{Block, Data, Hash, Log, Transaction}
  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.Optimism.{DisputeGame, MessageRelay, OutputRoot, WithdrawalEvent}
  alias Explorer.{Helper, PagingOptions, Repo}

  @game_status_defender_wins 2

  @withdrawal_status_waiting_for_state_root "Waiting for state root"
  @withdrawal_status_ready_to_prove "Ready to prove"
  @withdrawal_status_waiting_to_resolve "Waiting a game to resolve"
  @withdrawal_status_in_challenge "In challenge period"
  @withdrawal_status_ready_for_relay "Ready for relay"
  @withdrawal_status_proven "Proven"
  @withdrawal_status_relayed "Relayed"
  @withdrawal_status_relay_failed "Relay failed"

  @dispute_game_finality_delay_seconds "optimism_dispute_game_finality_delay_seconds"
  @proof_maturity_delay_seconds "optimism_proof_maturity_delay_seconds"

  # 32-byte signature of the event MessagePassed(uint256 indexed nonce, address indexed sender, address indexed target, uint256 value, uint256 gasLimit, bytes data, bytes32 withdrawalHash)
  @message_passed_event_standard "0x02a52367d10742d8032712c1bb8e0144ff1ec5ffda1ed7d70bb05a2744955054"

  # Mantle MessagePassed has an extra mntValue field:
  # MessagePassed(uint256 indexed nonce, address indexed sender, address indexed target, uint256 mntValue, uint256 ethValue, uint256 gasLimit, bytes data, bytes32 withdrawalHash)
  @message_passed_event_mantle "0x5da382596b838a63b4248e533d8e399b3b0f13ba6c6679f670489d44716cb173"

  @required_attrs ~w(msg_nonce hash l2_transaction_hash l2_block_number)a
  @optional_attrs ~w(message_hash transfer_type transfer_from_address_hash transfer_to_address_hash l1_token_address_hash
                     l2_token_address_hash transfer_amount mnt_value eth_value)a
  @game_fields ~w(created_at resolved_at status)a

  @api_true [api?: true]

  @typedoc """
    * `msg_nonce` - A nonce of the withdrawal message.
    * `hash` - A withdrawal hash.
    * `l2_transaction_hash` - An L2 transaction hash which initiated the withdrawal.
    * `l2_block_number` - A block number of the L2 transaction.
    * `message_hash` - The versioned hash of the cross-domain message, `nil` when the withdrawal was not sent through
      the L2CrossDomainMessenger.
    * `transfer_type` - `eth`, `mnt` or `erc20` for an authenticated bridge transfer, `message` for anything else.
    * `transfer_from_address_hash` / `transfer_to_address_hash` - The bridge sender and recipient. For a `message`: the
      messenger-level sender and target, or the `MessagePassed` sender and target when it is not a messenger message.
    * `l1_token_address_hash` / `l2_token_address_hash` - The token on each chain (`erc20` only).
    * `transfer_amount` - The bridged amount, `nil` for a `message`.
    * `mnt_value` / `eth_value` - The MNT and ETH values delivered with the message.
  """
  @primary_key false
  typed_schema "op_withdrawals" do
    field(:msg_nonce, :decimal, primary_key: true)
    field(:hash, Hash.Full)
    field(:l2_transaction_hash, Hash.Full)
    field(:l2_block_number, :integer)
    field(:message_hash, Hash.Full)
    field(:transfer_type, Ecto.Enum, values: [:eth, :mnt, :erc20, :message])
    field(:transfer_from_address_hash, Hash.Address)
    field(:transfer_to_address_hash, Hash.Address)
    field(:l1_token_address_hash, Hash.Address)
    field(:l2_token_address_hash, Hash.Address)
    field(:transfer_amount, :decimal)
    field(:mnt_value, :decimal)
    field(:eth_value, :decimal)

    timestamps()
  end

  def changeset(%__MODULE__{} = withdrawals, attrs \\ %{}) do
    withdrawals
    |> cast(attrs, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
  end

  @doc """
  Lists `t:Explorer.Chain.Optimism.Withdrawal.t/0`'s' in descending order based on message nonce.

  Accepts an optional `:address_hash` filter (`Hash.Address.t()` or `nil`). Once the bridge transfers are backfilled
  (`Explorer.Migrator.OptimismWithdrawalTransfers`) it matches the withdrawals the address sent or received through the
  bridge; until then, the withdrawals whose L2 transaction it sent.

  Each item also carries the relay result of its message: `message_hash`, `relay_status` (`:relayed`, `:failed`, or
  nil) and `relay_transaction_hash`, all read with one query per page.
  """
  @spec list :: [__MODULE__.t()]
  def list(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, default_paging_options())
    address_filter = options |> Keyword.get(:address_hash) |> address_filter()

    case paging_options do
      %PagingOptions{key: {0}} ->
        []

      _ ->
        event_topic = message_passed_event()
        message_passer = message_passer()

        base_query =
          from(w in withdrawals(address_filter, paging_options),
            as: :withdrawal,
            order_by: [desc: w.msg_nonce],
            left_join: l2_transaction in Transaction,
            as: :l2_transaction,
            on: w.l2_transaction_hash == l2_transaction.hash,
            left_join: l2_block in Block,
            on: w.l2_block_number == l2_block.number and l2_block.consensus == true,
            left_join: we in WithdrawalEvent,
            on: we.withdrawal_hash == w.hash and we.l1_event_type == :WithdrawalFinalized,
            left_join: log in Log,
            on:
              log.transaction_hash == w.l2_transaction_hash and log.block_hash == l2_block.hash and
                log.address_hash == ^message_passer and log.first_topic == ^event_topic and
                log.second_topic == fragment("numeric_to_bytea32(?)", w.msg_nonce),
            select: %{
              msg_nonce: w.msg_nonce,
              hash: w.hash,
              l2_block_number: w.l2_block_number,
              l2_timestamp: l2_block.timestamp,
              l2_transaction_hash: w.l2_transaction_hash,
              l1_transaction_hash: we.l1_transaction_hash,
              from: l2_transaction.from_address_hash,
              message_hash: w.message_hash,
              transfer_type: w.transfer_type,
              msg_log_sender_address_hash: log.third_topic,
              msg_log_target_address_hash: log.fourth_topic,
              msg_log_data: log.data
            }
          )

        repo = select_repo(options)

        base_query
        |> filter_by_initiator(address_filter)
        |> page_optimism_withdrawals(paging_options)
        |> limit(^paging_options.page_size)
        |> repo.all(timeout: :infinity)
        |> with_relays(repo)
    end
  end

  @doc """
    Returns total number of displayed withdrawals.

    ## Parameters
    - `options`: A keyword list of options:
      - `:api?` - Whether the function is being called from an API context.
      - `:address_hash` - An optional `Hash.Address.t()` to restrict the count to the withdrawals `list/1` returns
        for the address.

    ## Returns
    - A total number of withdrawals.
  """
  @spec count(list()) :: non_neg_integer()
  def count(options \\ []) do
    options
    |> Keyword.get(:address_hash)
    |> address_filter()
    |> count_query()
    |> select_repo(options).aggregate(:count)
  end

  # Once the transfers are backfilled, an address's withdrawals are counted from the two transfer address indexes alone
  defp count_query({:transfer, address_hash}) do
    from(w in __MODULE__,
      where: w.transfer_from_address_hash == ^address_hash or w.transfer_to_address_hash == ^address_hash
    )
  end

  defp count_query(address_filter) do
    from(w in __MODULE__,
      as: :withdrawal,
      left_join: l2_transaction in Transaction,
      as: :l2_transaction,
      on: w.l2_transaction_hash == l2_transaction.hash
    )
    |> filter_by_initiator(address_filter)
  end

  # An address matches the withdrawals it sent or received through the bridge once their transfers are backfilled, and
  # the withdrawals whose L2 transaction it sent until then. Read once per call, so that a call never mixes the two.
  defp address_filter(nil), do: nil

  defp address_filter(address_hash) do
    if BackgroundMigrations.get_optimism_withdrawal_transfers_finished(),
      do: {:transfer, address_hash},
      else: {:initiator, address_hash}
  end

  # A page of each side of the address, so that a heavy address reads at most two pages, each an ordered index range
  defp withdrawals({:transfer, address_hash}, paging_options) do
    sent = address_page(:transfer_from_address_hash, address_hash, paging_options)
    received = address_page(:transfer_to_address_hash, address_hash, paging_options)

    subquery(union(from(w in subquery(sent)), ^from(w in subquery(received))))
  end

  defp withdrawals(_address_filter, _paging_options), do: __MODULE__

  defp address_page(column, address_hash, paging_options) do
    from(w in __MODULE__,
      as: :withdrawal,
      where: field(w, ^column) == ^address_hash,
      order_by: [desc: w.msg_nonce],
      limit: ^paging_options.page_size
    )
    |> page_optimism_withdrawals(paging_options)
  end

  defp filter_by_initiator(query, {:initiator, address_hash}) do
    from([l2_transaction: l2_transaction] in query,
      where: l2_transaction.from_address_hash == ^address_hash
    )
  end

  defp filter_by_initiator(query, _address_filter), do: query

  defp page_optimism_withdrawals(query, %PagingOptions{key: nil}), do: query

  defp page_optimism_withdrawals(query, %PagingOptions{key: {nonce}}) do
    from([withdrawal: w] in query, where: w.msg_nonce < ^nonce)
  end

  @doc """
    Forms a query to find the last Withdrawal's L2 block number and transaction hash.
    Used by the `Indexer.Fetcher.Optimism.Withdrawal` module.

    ## Returns
    - A query which can be used by the `Repo.one` function.
  """
  @spec last_withdrawal_l2_block_number_query() :: Ecto.Queryable.t()
  def last_withdrawal_l2_block_number_query do
    from(w in __MODULE__,
      select: {w.l2_block_number, w.l2_transaction_hash},
      order_by: [desc: w.msg_nonce],
      limit: 1
    )
  end

  @doc """
    Forms a query to remove all Withdrawals related to the specified L2 block number.
    Used by the `Indexer.Fetcher.Optimism.Withdrawal` module.

    ## Parameters
    - `l2_block_number`: The L2 block number for which the Withdrawals should be removed
                         from the `op_withdrawals` database table.

    ## Returns
    - A query which can be used by the `delete_all` function.
  """
  @spec remove_withdrawals_query(non_neg_integer()) :: Ecto.Queryable.t()
  def remove_withdrawals_query(l2_block_number) do
    from(w in __MODULE__, where: w.l2_block_number == ^l2_block_number)
  end

  @doc """
    Gets withdrawal statuses for Optimism Withdrawal transaction.
    For each withdrawal associated with this transaction,
    returns the status, the corresponding L1 transaction hash if the status is `Relayed`,
    and withdrawal message's data (such as nonce, sender, target, etc.).

    ## Parameters
    - `l2_transaction_hash`: The transaction hash associated with the withdrawal.

    ## Returns
    - A tuple containing the withdrawal message nonce, the withdrawal status, and a map with other message's data.
  """
  @spec transaction_statuses(Hash.t()) :: [{non_neg_integer(), String.t(), map()}]
  def transaction_statuses(l2_transaction_hash) do
    event_topic = message_passed_event()
    message_passer = message_passer()

    query =
      from(w in __MODULE__,
        where: w.l2_transaction_hash == ^l2_transaction_hash,
        left_join: l2_block in Block,
        on: w.l2_block_number == l2_block.number and l2_block.consensus == true,
        left_join: we in WithdrawalEvent,
        on: we.withdrawal_hash == w.hash and we.l1_event_type == :WithdrawalFinalized,
        left_join: log in Log,
        on:
          log.transaction_hash == w.l2_transaction_hash and log.block_hash == l2_block.hash and
            log.address_hash == ^message_passer and log.first_topic == ^event_topic and
            log.second_topic == fragment("numeric_to_bytea32(msg_nonce)"),
        select: %{
          hash: w.hash,
          l2_block_number: w.l2_block_number,
          l1_transaction_hash: we.l1_transaction_hash,
          msg_nonce: w.msg_nonce,
          message_hash: w.message_hash,
          transfer_type: w.transfer_type,
          msg_log_sender_address_hash: log.third_topic,
          msg_log_target_address_hash: log.fourth_topic,
          msg_log_data: log.data
        }
      )

    repo = Repo.replica()

    query
    |> repo.all(timeout: :infinity)
    |> with_relays(repo)
    |> with_statuses(@api_true)
    |> Enum.map(fn w ->
      msg_nonce =
        Bitwise.band(
          Decimal.to_integer(w.msg_nonce),
          0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
        )

      {msg_nonce, w.status, w}
    end)
  end

  @doc """
    Adds `status`, `challenge_period_end` (only for `In challenge period`) and `prove_transaction_hash` (the latest
    `WithdrawalProven` transaction) to each withdrawal of a page.

    On chains without fault proofs, such as Mantle, a page costs a constant number of queries:
    - the `WithdrawalProven` events of all its withdrawals;
    - the latest output root;
    - the finalization period, which `Indexer.Fetcher.Optimism.OutputRoot` stores (no L1 call);
    - the respected dispute games, only on chains that store a respected game type.
    A fault-proof chain still looks the dispute game of each proving event up, as before.

    A message's relay result decides first (see `list/1`): `Relayed`, or `Relay failed` when no relay delivered it.
    OP Fault Proofs allow several WithdrawalProven events for one withdrawal, so all of them are weighed and the most
    advanced status wins. While no finalization period is stored, a proven withdrawal stays `In challenge period`
    without an end, rather than ending after a guessed period.

    ## Parameters
    - `withdrawals`: Maps with `hash`, `l2_block_number`, `l1_transaction_hash` (the finalizing transaction) and
      `relay_status`.
    - `options`: `[api?: true]` to read from the replica.

    ## Returns
    - The withdrawals with `status`, `challenge_period_end` and `prove_transaction_hash` added.
  """
  @spec with_statuses([map()], [Chain.api?()]) :: [map()]
  def with_statuses([], _options), do: []

  def with_statuses(withdrawals, options) do
    proven_events = proven_events(Enum.map(withdrawals, & &1.hash), options)

    context = %{
      last_root_l2_block_number: last_root_l2_block_number(options),
      finalization_period:
        Helper.parse_integer(Constants.get_constant_value(OutputRoot.finalization_period_constant(), options)),
      respected_games: respected_games(options)
    }

    Enum.map(withdrawals, fn w ->
      events = Map.get(proven_events, w.hash, [])
      {status, challenge_period_end} = status(w, events, context)

      prove_transaction_hash =
        case List.last(events) do
          {_l1_timestamp, _game_address_hash, _game_index, l1_transaction_hash} -> l1_transaction_hash
          nil -> nil
        end

      Map.merge(w, %{
        status: status,
        challenge_period_end: challenge_period_end,
        prove_transaction_hash: prove_transaction_hash
      })
    end)
  end

  # The messenger's relay result decides as soon as it is indexed: the portal emits `WithdrawalFinalized` with
  # `success = true` even when the relay fails, and a replay emits no portal event at all.
  defp status(%{relay_status: :relayed}, _events, _context), do: {@withdrawal_status_relayed, nil}
  defp status(%{relay_status: :failed}, _events, _context), do: {@withdrawal_status_relay_failed, nil}

  # Finalized without a known relay. `Indexer.Fetcher.Optimism.WithdrawalEvent` imports the relay of the finalizing
  # transaction together with the finalization, so this is a withdrawal not sent through the messenger, one finalized
  # before the relays were indexed or on a chain without the L1 messenger configured, or one whose message hash is not
  # known yet: its bridge transfer is not decoded and its `MessagePassed` log not indexed.
  defp status(%{l1_transaction_hash: l1_transaction_hash}, _events, _context) when not is_nil(l1_transaction_hash),
    do: {@withdrawal_status_relayed, nil}

  defp status(w, [], context) do
    if appropriate_games_found(w.l2_block_number, context.respected_games) or
         w.l2_block_number <= context.last_root_l2_block_number,
       do: {@withdrawal_status_ready_to_prove, nil},
       else: {@withdrawal_status_waiting_for_state_root, nil}
  end

  defp status(_w, events, context), do: handle_proven_status(events, context)

  @doc """
    Returns the list of games which type is equal to the current respected game type
    received from OptimismPortal contract.
  """
  @spec respected_games([Chain.api?()]) :: list()
  def respected_games(options) do
    case Helper.parse_integer(Constants.get_constant_value("optimism_respected_game_type", options)) do
      nil ->
        []

      game_type ->
        query =
          from(g in DisputeGame,
            where: g.game_type == ^game_type,
            order_by: [desc: g.index],
            limit: 100
          )

        Chain.select_repo(options).all(query, timeout: :infinity)
    end
  end

  @doc """
    Returns a name of the dispute_game_finality_delay_seconds constant.
  """
  @spec dispute_game_finality_delay_seconds_constant() :: binary()
  def dispute_game_finality_delay_seconds_constant do
    @dispute_game_finality_delay_seconds
  end

  @doc """
    Returns a name of the proof_maturity_delay_seconds constant.
  """
  @spec proof_maturity_delay_seconds_constant() :: binary()
  def proof_maturity_delay_seconds_constant do
    @proof_maturity_delay_seconds
  end

  defp appropriate_games_found(withdrawal_l2_block_number, respected_games) do
    respected_games
    |> Enum.any?(fn game ->
      l2_block_number = DisputeGame.l2_block_number_from_extra_data(game.extra_data)
      withdrawal_l2_block_number <= l2_block_number
    end)
  end

  defp last_root_l2_block_number(options) do
    select_repo(options).one(
      from(root in OutputRoot,
        select: root.l2_block_number,
        order_by: [desc: root.l2_output_index],
        limit: 1
      )
    ) || 0
  end

  # Fetches dispute game info from DB by game's contract address hash or game's unique index.
  #
  # ## Parameters
  # - `game_address_hash`: Game's contract address hash. Must be `nil` if unknown.
  # - `game_index`: Game unique index. Must be `nil` if unknown.
  #
  # ## Returns
  # - A map with necessary info about the dispute game.
  # - `nil` if the dispute game not found in DB or both input parameters are `nil`.
  @spec game_by_address_hash_or_index(Hash.t() | nil, non_neg_integer() | nil) ::
          %{:created_at => DateTime.t(), :resolved_at => DateTime.t(), :status => non_neg_integer()} | nil
  defp game_by_address_hash_or_index(nil, nil), do: nil

  defp game_by_address_hash_or_index(game_address_hash, nil) do
    Repo.replica().one(
      from(
        g in DisputeGame,
        select: map(g, ^@game_fields),
        where: g.address_hash == ^game_address_hash,
        limit: 1
      )
    )
  end

  defp game_by_address_hash_or_index(_game_address_hash, game_index) when not is_nil(game_index) do
    Repo.replica().one(
      from(
        g in DisputeGame,
        select: map(g, ^@game_fields),
        where: g.index == ^game_index
      )
    )
  end

  # Determines the current withdrawal status by the list of the bound WithdrawalProven events.
  #
  # ## Parameters
  # - `proven_events`: A list of WithdrawalProven events, each a `{l1_timestamp, game_address_hash, game_index,
  #   l1_transaction_hash}` tuple.
  # - `context`: The page's `respected_games` and `finalization_period` (see `with_statuses/2`).
  #
  # ## Returns
  # - `{status, datetime}` tuple where the `status` is the current withdrawal status,
  #                        `datetime` is the point of time when the challenge period ends.
  #                        (only for `In challenge period` status).
  @spec handle_proven_status(list(), map()) :: {String.t(), DateTime.t() | nil}
  defp handle_proven_status(proven_events, %{respected_games: respected_games} = context) do
    statuses =
      proven_events
      |> Enum.reduce_while([], fn {l1_timestamp, game_address_hash, game_index, _l1_transaction_hash}, acc ->
        game = game_by_address_hash_or_index(game_address_hash, game_index)

        # credo:disable-for-lines:16 Credo.Check.Refactor.PipeChainStart
        cond do
          is_nil(game) and not Enum.empty?(respected_games) ->
            # here we cannot exactly determine the status `Waiting a game to resolve` or
            # `Ready for relay` or `In challenge period`
            # as we don't know the game index and address. In this case we display the `Proven` status
            {@withdrawal_status_proven, nil}

          is_nil(game) or DateTime.compare(l1_timestamp, game.created_at) == :lt ->
            # the old status determining approach
            pre_fault_proofs_status(l1_timestamp, context.finalization_period)

          true ->
            # the new status determining approach
            post_fault_proofs_status(l1_timestamp, game)
        end
        |> case do
          {@withdrawal_status_ready_for_relay, _} = status -> {:halt, [status]}
          status -> {:cont, [status | acc]}
        end
      end)

    status_priority =
      %{}
      |> Map.put(@withdrawal_status_in_challenge, 30)
      |> Map.put(@withdrawal_status_waiting_to_resolve, 20)
      |> Map.put(@withdrawal_status_proven, 10)

    statuses
    |> Enum.sort_by(
      fn {s, timestamp} ->
        {status_priority[s], if(not is_nil(timestamp), do: -DateTime.to_unix(timestamp))}
      end,
      :desc
    )
    |> List.first()
  end

  # Reads the WithdrawalProven events of the given withdrawals from `op_withdrawal_events`, oldest first.
  #
  # ## Returns
  # - A `withdrawal hash => events` map, each event a `{l1_timestamp, game_address_hash, game_index,
  #   l1_transaction_hash}` tuple. `game_address_hash` and `game_index` are `nil` without fault proofs.
  @spec proven_events([Hash.t()], [Chain.api?()]) :: %{
          Hash.t() => [{DateTime.t(), Hash.t() | nil, non_neg_integer() | nil, Hash.t()}]
        }
  defp proven_events(withdrawal_hashes, options) do
    from(
      we in WithdrawalEvent,
      where: we.withdrawal_hash in ^Enum.uniq(withdrawal_hashes) and we.l1_event_type == :WithdrawalProven,
      order_by: [asc: we.l1_block_number],
      select: {we.withdrawal_hash, {we.l1_timestamp, we.game_address_hash, we.game_index, we.l1_transaction_hash}}
    )
    |> select_repo(options).all(timeout: :infinity)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp pre_fault_proofs_status(_l1_timestamp, nil = _challenge_period), do: {@withdrawal_status_in_challenge, nil}

  defp pre_fault_proofs_status(l1_timestamp, challenge_period) do
    if DateTime.compare(l1_timestamp, DateTime.add(DateTime.utc_now(), -challenge_period)) == :lt do
      {@withdrawal_status_ready_for_relay, nil}
    else
      {@withdrawal_status_in_challenge, DateTime.add(l1_timestamp, challenge_period)}
    end
  end

  defp post_fault_proofs_status(l1_timestamp, game) do
    if game.status != @game_status_defender_wins do
      # the game status is not DEFENDER_WINS
      {@withdrawal_status_waiting_to_resolve, nil}
    else
      dispute_game_finality_delay_seconds =
        Helper.parse_integer(Constants.get_constant_value(@dispute_game_finality_delay_seconds))

      proof_maturity_delay_seconds = Helper.parse_integer(Constants.get_constant_value(@proof_maturity_delay_seconds))

      false = is_nil(dispute_game_finality_delay_seconds)
      false = is_nil(proof_maturity_delay_seconds)

      finality_delayed = DateTime.add(game.resolved_at, dispute_game_finality_delay_seconds)
      proof_delayed = DateTime.add(l1_timestamp, proof_maturity_delay_seconds)

      now = DateTime.utc_now()

      if DateTime.compare(now, finality_delayed) == :lt or DateTime.compare(now, finality_delayed) == :eq or
           DateTime.compare(now, proof_delayed) == :lt or DateTime.compare(now, proof_delayed) == :eq do
        seconds_left1 = max(DateTime.diff(finality_delayed, now), 0)
        seconds_left2 = max(DateTime.diff(proof_delayed, now), 0)
        seconds_left = max(seconds_left1, seconds_left2)

        {@withdrawal_status_in_challenge, DateTime.add(now, seconds_left)}
      else
        {@withdrawal_status_ready_for_relay, nil}
      end
    end
  end

  # Adds the messenger relay result of each withdrawal, reading all of them with one query from `repo`, the one the
  # withdrawals were read from: `message_hash` (nil when the message was not sent through the L2CrossDomainMessenger),
  # `relay_status` (`:relayed`, `:failed`, or nil when no relay is indexed) and `relay_transaction_hash` (the
  # delivering L1 transaction, a replay if the first relay failed).
  @spec with_relays([map()], module()) :: [map()]
  defp with_relays(withdrawals, repo) do
    messenger = MessageRelay.l2_cross_domain_messenger()
    mantle_mode = mantle_mode?()
    message_hashes = Enum.map(withdrawals, &message_hash(&1, messenger, mantle_mode))

    summaries =
      message_hashes
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> MessageRelay.summaries(:l1, repo: repo)

    withdrawals
    |> Enum.zip(message_hashes)
    |> Enum.map(fn {withdrawal, message_hash} ->
      summary = Map.get(summaries, message_hash, %{})

      Map.merge(withdrawal, %{
        message_hash: message_hash,
        relay_status: summary[:status],
        relay_transaction_hash: summary[:transaction_hash]
      })
    end)
  end

  # The stored hash once the bridge transfer is decoded. Until then the hash of the `MessagePassed` log, which the block
  # fetcher may not have indexed yet: the withdrawal fetcher reads the event from the node. Without its hash, a
  # finalized withdrawal would read as `Relayed` whatever its relay.
  defp message_hash(%{transfer_type: type, message_hash: message_hash}, _messenger, _mantle_mode) when not is_nil(type),
    do: message_hash

  defp message_hash(withdrawal, messenger, mantle_mode), do: relay_message_hash(withdrawal, messenger, mantle_mode)

  # Only the L2CrossDomainMessenger emits `MessagePassed` with itself as the sender, so `data` is then the
  # `relayMessage` calldata whose keccak256 the L1CrossDomainMessenger emits when relaying.
  defp relay_message_hash(
         %{msg_log_sender_address_hash: %Hash{} = sender, msg_log_data: %Data{} = msg_log_data},
         messenger,
         mantle_mode
       ) do
    if Helper.truncate_address_hash(sender) == messenger do
      msg_log_data
      |> parse_message_passed_data(mantle_mode)
      |> Map.fetch!(:data)
      |> MessageRelay.message_hash()
    end
  end

  defp relay_message_hash(_withdrawal, _messenger, _mantle_mode), do: nil

  @doc """
    Decodes the non-indexed fields of a `MessagePassed` event. Mantle's event has five (mntValue, ethValue, gasLimit,
    data, withdrawalHash); the OP Stack one has four (value, gasLimit, data, withdrawalHash), and then `mnt_value` is
    `nil` and `eth_value` is the value.
  """
  @spec parse_message_passed_data(Data.t() | String.t(), boolean()) :: %{
          mnt_value: non_neg_integer() | nil,
          eth_value: non_neg_integer(),
          gas_limit: non_neg_integer(),
          data: binary(),
          hash: binary()
        }
  def parse_message_passed_data(data, mantle_mode \\ mantle_mode?())

  def parse_message_passed_data(data, true = _mantle_mode) do
    [mnt_value, eth_value, gas_limit, message, hash] =
      Helper.decode_data(data, [{:uint, 256}, {:uint, 256}, {:uint, 256}, :bytes, {:bytes, 32}])

    %{mnt_value: mnt_value, eth_value: eth_value, gas_limit: gas_limit, data: message, hash: hash}
  end

  def parse_message_passed_data(data, false = _mantle_mode) do
    [value, gas_limit, message, hash] = Helper.decode_data(data, [{:uint, 256}, {:uint, 256}, :bytes, {:bytes, 32}])

    %{mnt_value: nil, eth_value: value, gas_limit: gas_limit, data: message, hash: hash}
  end

  @doc """
    Returns a signature of the `MessagePassed` event emitted by `L2ToL1MessagePasser` contract
    in form of 0x-prefixed string.

    ## Returns
    - A 0x-prefixed string representing the signature.
  """
  @spec message_passed_event() :: String.t()
  def message_passed_event do
    if mantle_mode?() do
      @message_passed_event_mantle
    else
      @message_passed_event_standard
    end
  end

  defp mantle_mode? do
    Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism][:mantle_mode] == true
  end

  @doc """
    Returns the L2ToL1MessagePasser address. Only its own `MessagePassed` events describe a withdrawal: any contract
    the withdrawal transaction calls can emit an event with the same signature and topics.
  """
  @spec message_passer() :: String.t()
  def message_passer do
    Application.get_env(:indexer, Indexer.Fetcher.Optimism.Withdrawal, [])[:message_passer] ||
      "0x4200000000000000000000000000000000000016"
  end

  @doc """
    Returns `OptimismPortal` contract address. First, the function tries to get the address from the
    `INDEXER_OPTIMISM_L1_PORTAL_CONTRACT` env variable. If that's not defined, the address is retrieved
    from the database (constants table) where it was saved by other modules. If the address is unknown,
    the function returns `nil`.

    ## Returns
    - The OptimismPortal contract address in form of 0x-prefixed string.
    - `nil` if the address cannot be determined.
  """
  @spec portal_contract_address() :: String.t() | nil
  def portal_contract_address do
    portal_address = Application.get_all_env(:indexer)[Indexer.Fetcher.Optimism][:portal]

    if Indexer.Helper.address_correct?(portal_address) do
      portal_address
    else
      Constants.get_constant_value(portal_contract_address_constant(), @api_true)
    end
  end

  @doc """
  Returns the name of the optimism_portal_contract_address constant.
  """
  @spec portal_contract_address_constant() :: binary()
  def portal_contract_address_constant, do: "optimism_portal_contract_address"
end
