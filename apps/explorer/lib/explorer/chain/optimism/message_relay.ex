defmodule Explorer.Chain.Optimism.MessageRelay do
  @moduledoc """
    Models the relay result of a cross-domain message: a `RelayedMessage` or `FailedRelayedMessage` event of the
    L1CrossDomainMessenger (relays of withdrawals) or of the L2CrossDomainMessenger (relays of deposits).

    Every event is kept, because a message can fail several times before a replay delivers it. Rows are keyed by
    the versioned message hash, which is `keccak256` of the `relayMessage` calldata (see `message_hash/1`).
  """

  use Explorer.Schema

  import EthereumJSONRPC, only: [quantity_to_integer: 1]
  import Explorer.Chain, only: [select_repo: 1]

  alias Explorer.Chain
  alias Explorer.Chain.Hash

  @required_attrs ~w(message_hash event_type transaction_hash chain block_number)a

  # 32-byte signature of the event RelayedMessage(bytes32 indexed msgHash)
  @relayed_message_event "0x4641df4a962071e12719d8c8c8e5ac7fc4d97b927346a3d7a335b1f7517e133c"

  # 32-byte signature of the event FailedRelayedMessage(bytes32 indexed msgHash)
  @failed_relayed_message_event "0x99d0e048484baa1b1540b1367cb128acd7ab2946d1ed91ec10e3c85e4bf51b8f"

  @l2_cross_domain_messenger_predeploy "0x4200000000000000000000000000000000000007"

  # 4-byte selectors of relayMessage(uint256,address,address,uint256,uint256,uint256,bytes) (Mantle)
  # and relayMessage(uint256,address,address,uint256,uint256,bytes) (OP Stack)
  @relay_message_selectors [<<0xFF, 0x8D, 0xAF, 0x15>>, <<0xD7, 0x64, 0xAD, 0x0B>>]

  @type chain :: :l1 | :l2

  @type summary :: %{status: :relayed | :failed, transaction_hash: Hash.Full.t() | nil}

  @type to_import :: %{
          message_hash: String.t(),
          event_type: :RelayedMessage | :FailedRelayedMessage,
          transaction_hash: String.t(),
          chain: chain(),
          block_number: non_neg_integer()
        }

  @typedoc """
    * `message_hash` - The versioned hash of the message (the indexed `msgHash` event parameter).
    * `event_type` - `RelayedMessage` (delivered) or `FailedRelayedMessage` (stored for a replay).
    * `transaction_hash` - The transaction that emitted the event.
    * `chain` - `l1` for relays of withdrawals, `l2` for relays of deposits.
    * `block_number` - The block of that transaction.
  """
  @primary_key false
  typed_schema "op_message_relays" do
    field(:message_hash, Hash.Full, primary_key: true)
    field(:event_type, Ecto.Enum, values: [:RelayedMessage, :FailedRelayedMessage], primary_key: true)
    field(:transaction_hash, Hash.Full, primary_key: true)
    field(:chain, Ecto.Enum, values: [:l1, :l2])
    field(:block_number, :integer)

    timestamps()
  end

  def changeset(%__MODULE__{} = relay, attrs \\ %{}) do
    relay
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
  end

  @doc """
    Returns the `topic0` values of the `RelayedMessage` and `FailedRelayedMessage` events.
  """
  @spec relay_events() :: [String.t()]
  def relay_events, do: [@relayed_message_event, @failed_relayed_message_event]

  @doc """
    Converts `RelayedMessage` and `FailedRelayedMessage` logs returned by `eth_getLogs` into params for
    `Chain.import/1`. Other logs are ignored. Duplicates are dropped, because one insert cannot update a row twice.
  """
  @spec events_to_relays([map()], chain()) :: [to_import()]
  def events_to_relays(events, chain) do
    events
    |> Enum.flat_map(&event_to_relays(&1, chain))
    |> Enum.uniq_by(&{&1.message_hash, &1.event_type, &1.transaction_hash})
  end

  defp event_to_relays(%{"topics" => [signature, message_hash | _]} = event, chain) do
    case String.downcase(signature) do
      @relayed_message_event -> [relay(event, message_hash, :RelayedMessage, chain)]
      @failed_relayed_message_event -> [relay(event, message_hash, :FailedRelayedMessage, chain)]
      _ -> []
    end
  end

  defp event_to_relays(_event, _chain), do: []

  defp relay(event, message_hash, event_type, chain) do
    %{
      message_hash: message_hash,
      event_type: event_type,
      transaction_hash: event["transactionHash"],
      chain: chain,
      block_number: quantity_to_integer(event["blockNumber"])
    }
  end

  @doc """
    Returns the versioned hash of a cross-domain message given its `relayMessage` calldata, or `nil` when the
    calldata is not a `relayMessage` call.

    The messengers emit `keccak256(relayMessage calldata)` in `RelayedMessage` and `FailedRelayedMessage`. The
    calldata is `MessagePassed.data` for a withdrawal and the L2 deposit transaction input for a deposit.
  """
  @spec message_hash(binary() | nil) :: Hash.Full.t() | nil
  def message_hash(<<selector::binary-size(4), _::binary>> = calldata) when selector in @relay_message_selectors do
    {:ok, hash} = Hash.Full.cast(ExKeccak.hash_256(calldata))
    hash
  end

  def message_hash(_calldata), do: nil

  @doc """
    Returns the L2CrossDomainMessenger address in lower case: the predeploy, unless
    INDEXER_OPTIMISM_L2_CROSS_DOMAIN_MESSENGER_CONTRACT overrides it.
  """
  @spec l2_cross_domain_messenger() :: String.t()
  def l2_cross_domain_messenger do
    env = Application.get_env(:indexer, Indexer.Fetcher.Optimism.MessageRelayL2, [])
    String.downcase(env[:l2_cross_domain_messenger] || @l2_cross_domain_messenger_predeploy)
  end

  @doc """
    Summarizes the relays of the given messages on one chain with a single query.

    A message is `:relayed` as soon as a `RelayedMessage` exists, even after failures: the messenger keeps
    `failedMessages[hash]` set after a successful replay, so success takes precedence. It is `:failed` when only
    `FailedRelayedMessage` events exist. Messages without any relay are absent from the result.

    Each message costs two primary-key probes limited to one row, so a message that keeps failing (replays are
    cheap on L2) does not make the page that shows it read its whole history.

    ## Parameters
    - `message_hashes`: The versioned message hashes.
    - `chain`: `:l1` for withdrawals, `:l2` for deposits.
    - `options`: `api?: true` reads from the replica.

    ## Returns
    - A map `message_hash => %{status: :relayed | :failed, transaction_hash: delivering transaction or nil}`.
  """
  @spec summaries([Hash.Full.t()], chain(), [Chain.api?()]) :: %{Hash.Full.t() => summary()}
  def summaries(message_hashes, chain, options \\ [])

  def summaries([], _chain, _options), do: %{}

  def summaries(message_hashes, chain, options) do
    # the messenger delivers a message at most once, after any number of failures
    delivery =
      from(relay in __MODULE__,
        where:
          relay.message_hash == parent_as(:messages).message_hash and relay.event_type == :RelayedMessage and
            relay.chain == ^chain,
        order_by: [desc: relay.block_number],
        limit: 1,
        select: %{transaction_hash: relay.transaction_hash}
      )

    failure =
      from(relay in __MODULE__,
        where:
          relay.message_hash == parent_as(:messages).message_hash and relay.event_type == :FailedRelayedMessage and
            relay.chain == ^chain,
        limit: 1,
        select: %{block_number: relay.block_number}
      )

    from(
      message in fragment("SELECT unnest(?) AS message_hash", type(^message_hashes, {:array, Hash.Full})),
      as: :messages,
      left_lateral_join: delivered in subquery(delivery),
      on: true,
      left_lateral_join: failed in subquery(failure),
      on: true,
      where: not is_nil(delivered.transaction_hash) or not is_nil(failed.block_number),
      select: {type(message.message_hash, Hash.Full), delivered.transaction_hash}
    )
    |> select_repo(options).all(timeout: :infinity)
    |> Map.new(fn
      {message_hash, nil} -> {message_hash, %{status: :failed, transaction_hash: nil}}
      {message_hash, transaction_hash} -> {message_hash, %{status: :relayed, transaction_hash: transaction_hash}}
    end)
  end

  @doc """
    Forms a query for the block number and transaction hash of the last relay on the given chain.
    Used by the relay fetchers to resume after a restart or a reorg.
  """
  @spec last_relay_query(chain()) :: Ecto.Queryable.t()
  def last_relay_query(chain) do
    from(relay in __MODULE__,
      select: {relay.block_number, relay.transaction_hash},
      where: relay.chain == ^chain,
      order_by: [desc: relay.block_number],
      limit: 1
    )
  end

  @doc """
    Forms a query removing the relays of the given chain in the given block.
  """
  @spec remove_block_relays_query(chain(), non_neg_integer()) :: Ecto.Queryable.t()
  def remove_block_relays_query(chain, block_number) do
    from(relay in __MODULE__, where: relay.chain == ^chain and relay.block_number == ^block_number)
  end

  @doc """
    Forms a query removing the relays of the given chain from the given block on. Used for reorgs.
  """
  @spec remove_relays_from_block_query(chain(), non_neg_integer()) :: Ecto.Queryable.t()
  def remove_relays_from_block_query(chain, block_number) do
    from(relay in __MODULE__, where: relay.chain == ^chain and relay.block_number >= ^block_number)
  end
end
