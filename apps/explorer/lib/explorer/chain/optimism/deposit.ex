defmodule Explorer.Chain.Optimism.Deposit do
  @moduledoc "Models a deposit for Optimism."

  use Explorer.Schema

  import Explorer.Chain, only: [default_paging_options: 0, select_repo: 1]

  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Chain.{Data, Hash, Transaction}
  alias Explorer.Chain.Optimism.MessageRelay
  alias Explorer.PagingOptions

  @required_attrs ~w(l1_block_number l1_transaction_hash l1_transaction_origin l2_transaction_hash)a
  @optional_attrs ~w(l1_block_timestamp message_hash transfer_type transfer_from_address_hash transfer_to_address_hash
                     l1_token_address_hash l2_token_address_hash transfer_amount mnt_value eth_value)a
  @allowed_attrs @required_attrs ++ @optional_attrs

  @typedoc """
    * `l1_block_number` - The block number on L1 when the L1 transaction occurred.
    * `l1_block_timestamp` - Timestamp of the L1 block.
    * `l1_transaction_hash` - The deposit transaction hash on L1.
    * `l1_transaction_origin` - Origin address of the deposit.
    * `l2_transaction_hash` - The corresponding L2 transaction hash of the deposit.
    * `l2_transaction` - An instance of `Explorer.Chain.Transaction` referenced by `l2_transaction_hash`.
    * `message_hash` - The versioned hash of the cross-domain message, `nil` when the deposit is not a messenger message.
    * `transfer_type` - `eth`, `mnt` or `erc20` for an authenticated bridge transfer, `message` for anything else.
    * `transfer_from_address_hash` / `transfer_to_address_hash` - The bridge sender and recipient. For a `message`: the
      messenger-level sender and target, or the deposit's `from` and `to` when it is not a messenger message.
    * `l1_token_address_hash` / `l2_token_address_hash` - The token on each chain (`erc20` only).
    * `transfer_amount` - The bridged amount, `nil` for a `message`.
    * `mnt_value` / `eth_value` - The MNT and ETH values delivered with the message.
  """
  @primary_key false
  typed_schema "op_deposits" do
    field(:l1_block_number, :integer)
    field(:l1_block_timestamp, :utc_datetime_usec)
    field(:l1_transaction_hash, Hash.Full)
    field(:l1_transaction_origin, Hash.Address)
    field(:message_hash, Hash.Full)
    field(:transfer_type, Ecto.Enum, values: [:eth, :mnt, :erc20, :message])
    field(:transfer_from_address_hash, Hash.Address)
    field(:transfer_to_address_hash, Hash.Address)
    field(:l1_token_address_hash, Hash.Address)
    field(:l2_token_address_hash, Hash.Address)
    field(:transfer_amount, :decimal)
    field(:mnt_value, :decimal)
    field(:eth_value, :decimal)

    belongs_to(:l2_transaction, Transaction,
      foreign_key: :l2_transaction_hash,
      primary_key: true,
      references: :hash,
      type: Hash.Full
    )

    timestamps()
  end

  def changeset(%__MODULE__{} = deposit, attrs \\ %{}) do
    deposit
    |> cast(attrs, @allowed_attrs)
    |> validate_required(@required_attrs)
    |> foreign_key_constraint(:l2_transaction_hash)
  end

  def last_deposit_l1_block_number_query do
    from(d in __MODULE__,
      select: {d.l1_block_number, d.l1_transaction_hash},
      order_by: [desc: d.l1_block_number],
      limit: 1
    )
  end

  @doc """
    Forms a query to remove all Deposits with the specified L1 block number.
    Used by the `Indexer.Fetcher.Optimism.Deposit` module.

    ## Parameters
    - `l1_block_number`: The L1 block number for which the Deposits should be removed
                         from the `op_deposits` database table.

    ## Returns
    - A query which can be used by the `delete_all` function.
  """
  @spec remove_deposits_query(non_neg_integer()) :: Ecto.Queryable.t()
  def remove_deposits_query(l1_block_number) do
    from(d in __MODULE__, where: d.l1_block_number == ^l1_block_number)
  end

  @doc """
  Lists `t:Explorer.Chain.Optimism.Deposit.t/0`'s' in descending order based on l1_block_number and l2_transaction_hash.

  Accepts an optional `:address_hash` filter (`Hash.Address.t()` or `nil`). Once the bridge transfers are backfilled
  (`Explorer.Migrator.OptimismDepositTransfers`) it matches the deposits the address sent or received through the
  bridge; until then, the deposits whose L1 origin it is.

  Each item also carries the L2 relay result of its message (`message_hash`, `relay_status`, `relay_transaction_hash`)
  and what a replay needs (`msg_data`, `msg_target_address_hash`), all read with one query per page.
  """
  @spec list :: [__MODULE__.t()]
  def list(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, default_paging_options())
    address_filter = options |> Keyword.get(:address_hash) |> address_filter()

    case paging_options do
      %PagingOptions{key: {0, _l2_transaction_hash}} ->
        []

      _ ->
        base_query =
          from(
            d in deposits(address_filter, paging_options),
            inner_join: t in Transaction,
            on: t.hash == d.l2_transaction_hash and t.status == :ok,
            select: %{
              l1_block_number: d.l1_block_number,
              l1_block_timestamp: d.l1_block_timestamp,
              l1_transaction_hash: d.l1_transaction_hash,
              l1_transaction_origin: d.l1_transaction_origin,
              l2_transaction_hash: d.l2_transaction_hash,
              l2_transaction_gas_limit: t.gas,
              l2_transaction_to_address_hash: t.to_address_hash,
              l2_transaction_input: t.input
            },
            order_by: [desc: d.l1_block_number, desc: d.l2_transaction_hash]
          )

        repo = select_repo(options)

        base_query
        |> filter_by_origin(address_filter)
        |> page_deposits(paging_options)
        |> limit(^paging_options.page_size)
        |> repo.all(timeout: :infinity)
        |> with_relays(repo)
    end
  end

  @doc """
    Returns total number of displayed deposits.

    ## Parameters
    - `options`: A keyword list of options:
      - `:api?` - Whether the function is being called from an API context.
      - `:address_hash` - An optional `Hash.Address.t()` to restrict the count to the address's deposits, as
        `list/1` matches them. Once the bridge transfers are backfilled this also counts the address's deposits whose
        L2 transaction is pending or failed, which `list/1` leaves out.

    ## Returns
    - A total number of deposits.
  """
  @spec count(list()) :: non_neg_integer()
  def count(options \\ []) do
    options
    |> Keyword.get(:address_hash)
    |> address_filter()
    |> count_query()
    |> select_repo(options).aggregate(:count)
  end

  # Once the transfers are backfilled, an address's deposits are counted from the two transfer address indexes alone,
  # without probing `transactions` once per deposit, so a heavy address stays cheap to count. Unlike `list/1`, the
  # count then includes deposits whose L2 transaction is pending or failed.
  defp count_query({:transfer, address_hash}) do
    from(d in __MODULE__,
      where: d.transfer_from_address_hash == ^address_hash or d.transfer_to_address_hash == ^address_hash
    )
  end

  defp count_query(address_filter) do
    from(d in __MODULE__, inner_join: t in Transaction, on: t.hash == d.l2_transaction_hash and t.status == :ok)
    |> filter_by_origin(address_filter)
  end

  # An address matches the deposits it sent or received through the bridge once their transfers are backfilled, and the
  # deposits it originated on L1 until then. Read once per call, so that a call never mixes the two.
  defp address_filter(nil), do: nil

  defp address_filter(address_hash) do
    if BackgroundMigrations.get_optimism_deposit_transfers_finished(),
      do: {:transfer, address_hash},
      else: {:origin, address_hash}
  end

  # A page of each side of the address, so that a heavy address reads at most two pages, each an ordered index range
  defp deposits({:transfer, address_hash}, paging_options) do
    sent = address_page(:transfer_from_address_hash, address_hash, paging_options)
    received = address_page(:transfer_to_address_hash, address_hash, paging_options)

    subquery(union(from(d in subquery(sent)), ^from(d in subquery(received))))
  end

  defp deposits(_address_filter, _paging_options), do: __MODULE__

  defp address_page(column, address_hash, paging_options) do
    from(d in __MODULE__,
      inner_join: t in Transaction,
      on: t.hash == d.l2_transaction_hash and t.status == :ok,
      where: field(d, ^column) == ^address_hash,
      order_by: [desc: d.l1_block_number, desc: d.l2_transaction_hash],
      limit: ^paging_options.page_size
    )
    |> page_deposits(paging_options)
  end

  defp filter_by_origin(query, {:origin, address_hash}) do
    from(d in query, where: d.l1_transaction_origin == ^address_hash)
  end

  defp filter_by_origin(query, _address_filter), do: query

  # Adds the L2 relay result of each deposit (one query for the page, from `repo`, the one the deposits were read from)
  # and, for deposits relayed by the L2CrossDomainMessenger, the replay transaction data: the L2 transaction input and
  # its target.
  @spec with_relays([map()], module()) :: [map()]
  defp with_relays(deposits, repo) do
    messenger = MessageRelay.l2_cross_domain_messenger()
    message_hashes = Enum.map(deposits, &relay_message_hash(&1, messenger))

    summaries =
      message_hashes
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> MessageRelay.summaries(:l2, repo: repo)

    deposits
    |> Enum.zip(message_hashes)
    |> Enum.map(fn {deposit, message_hash} ->
      summary = Map.get(summaries, message_hash, %{})

      {msg_data, msg_target_address_hash} =
        if is_nil(message_hash),
          do: {nil, nil},
          else: {deposit.l2_transaction_input, deposit.l2_transaction_to_address_hash}

      deposit
      |> Map.drop([:l2_transaction_input, :l2_transaction_to_address_hash])
      |> Map.merge(%{
        message_hash: message_hash,
        relay_status: summary[:status],
        relay_transaction_hash: summary[:transaction_hash],
        msg_data: msg_data,
        msg_target_address_hash: msg_target_address_hash
      })
    end)
  end

  # The L2 transaction of a deposit relayed by the L2CrossDomainMessenger calls its relayMessage, so the input is the
  # calldata whose keccak256 the messenger emits.
  defp relay_message_hash(
         %{
           l2_transaction_to_address_hash: %Hash{} = to_address_hash,
           l2_transaction_input: %Data{bytes: input}
         },
         messenger
       ) do
    if Hash.to_string(to_address_hash) == messenger do
      MessageRelay.message_hash(input)
    end
  end

  defp relay_message_hash(_deposit, _messenger), do: nil

  defp page_deposits(query, %PagingOptions{key: nil}), do: query

  # A row comparison keeps the filters added before it (`or_where` would OR with them) and lets Postgres start the
  # index scan right at the page key.
  defp page_deposits(query, %PagingOptions{key: {block_number, l2_transaction_hash}}) do
    from(d in query,
      where:
        fragment(
          "(?, ?) < (?, ?)",
          d.l1_block_number,
          d.l2_transaction_hash,
          type(^block_number, :integer),
          type(^l2_transaction_hash, Hash.Full)
        )
    )
  end
end
