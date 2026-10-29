# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Optimism.OutputRoot do
  @moduledoc "Models an output root for Optimism."

  use Explorer.Schema

  import Explorer.Chain, only: [default_paging_options: 0, join_associations: 2, select_repo: 1]

  alias Explorer.Application.Constants
  alias Explorer.Chain
  alias Explorer.Chain.{Block, Hash, Transaction}
  alias Explorer.{Helper, PagingOptions}

  @required_attrs ~w(l2_output_index l2_block_number l1_transaction_hash l1_timestamp l1_block_number output_root)a

  @l1_safe_block_number_constant "optimism_l1_safe_block_number"
  @l1_finalized_block_number_constant "optimism_l1_finalized_block_number"
  @starting_block_number_constant "optimism_output_oracle_starting_block_number"
  @finalization_period_constant "optimism_output_oracle_finalization_period_seconds"

  # Largest value of the bigint primary key.
  @max_index 9_223_372_036_854_775_807

  # Counting visits one heap page per transaction, so a dense range can take minutes (228 s for one
  # hoodi-qa3 stress-test root). Past this limit the count is reported as unknown.
  @transactions_count_timeout_ms 5_000

  @typedoc """
    * `l2_output_index` - A unique index of the output root.
    * `l2_block_number` - An L2 block number of the output root.
    * `l1_transaction_hash` - An L1 transaction hash where an event with the output root appeared.
    * `l1_timestamp` - A timestamp of the L1 transaction block.
    * `l1_block_number` - A block number of the L1 transaction.
    * `output_root` - The output root.
  """
  @primary_key false
  typed_schema "op_output_roots" do
    field(:l2_output_index, :integer, primary_key: true)
    field(:l2_block_number, :integer)
    field(:l1_transaction_hash, Hash.Full)
    field(:l1_timestamp, :utc_datetime_usec)
    field(:l1_block_number, :integer)
    field(:output_root, Hash.Full)

    timestamps()
  end

  def changeset(%__MODULE__{} = output_roots, attrs \\ %{}) do
    output_roots
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
  end

  @doc """
  Lists `t:Explorer.Chain.Optimism.OutputRoot.t/0`'s' in descending order based on output root index.

  """
  @spec list :: [__MODULE__.t()]
  def list(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, default_paging_options())

    case paging_options do
      %PagingOptions{key: {0}} ->
        []

      _ ->
        base_query =
          from(r in __MODULE__,
            order_by: [desc: r.l2_output_index],
            select: r
          )

        base_query
        |> page_output_roots(paging_options)
        |> limit(^paging_options.page_size)
        |> select_repo(options).all(timeout: :infinity)
    end
  end

  @doc "Name of the constant holding the latest L1 `safe` block number, written by `Indexer.Fetcher.Optimism.OutputRoot`."
  @spec l1_safe_block_number_constant() :: binary()
  def l1_safe_block_number_constant, do: @l1_safe_block_number_constant

  @doc "Name of the constant holding the latest L1 `finalized` block number, written by `Indexer.Fetcher.Optimism.OutputRoot`."
  @spec l1_finalized_block_number_constant() :: binary()
  def l1_finalized_block_number_constant, do: @l1_finalized_block_number_constant

  @doc "Name of the constant holding the output oracle's `startingBlockNumber()`, written by `Indexer.Fetcher.Optimism.OutputRoot`."
  @spec starting_block_number_constant() :: binary()
  def starting_block_number_constant, do: @starting_block_number_constant

  @doc "Name of the constant holding the output oracle's `FINALIZATION_PERIOD_SECONDS()`, written by `Indexer.Fetcher.Optimism.OutputRoot`."
  @spec finalization_period_constant() :: binary()
  def finalization_period_constant, do: @finalization_period_constant

  @doc """
    Returns the output root with the given `l2OutputIndex`, or `nil` when it is not indexed or the index
    is outside the bigint range.
  """
  @spec by_index(integer(), [Chain.api?()]) :: t() | nil
  def by_index(index, options \\ [])

  def by_index(index, options) when is_integer(index) and index >= 0 and index <= @max_index do
    select_repo(options).get(__MODULE__, index)
  end

  def by_index(_index, _options), do: nil

  @doc """
    Returns the inclusive L2 block range `{start, end}` committed by `root`.

    The range starts right after the previous root (exactly `l2_output_index - 1`), or right after the
    oracle's `startingBlockNumber()` for index 0. The start is `nil` when that anchor is not known: the
    range is then unknown and must not be guessed.
  """
  @spec block_range(t(), [Chain.api?()]) :: {non_neg_integer() | nil, non_neg_integer()}
  def block_range(root, options \\ [])

  def block_range(%__MODULE__{l2_output_index: 0, l2_block_number: end_block}, options) do
    {increment(constant_integer(@starting_block_number_constant, options)), end_block}
  end

  def block_range(%__MODULE__{l2_output_index: index, l2_block_number: end_block}, options) do
    previous_end =
      select_repo(options).one(
        from(root in __MODULE__, where: root.l2_output_index == ^(index - 1), select: root.l2_block_number)
      )

    {increment(previous_end), end_block}
  end

  @doc """
    Returns the L1 finality of an L1 block number: `:finalized` at or below the stored L1 finalized head,
    `:safe` at or below the stored safe head, `:unsafe` above it, or `nil` while no heads are stored.
  """
  @spec l1_finality(non_neg_integer(), [Chain.api?()]) :: :finalized | :safe | :unsafe | nil
  def l1_finality(l1_block_number, options \\ []) do
    finalized = constant_integer(@l1_finalized_block_number_constant, options)
    safe = constant_integer(@l1_safe_block_number_constant, options)

    cond do
      is_nil(finalized) and is_nil(safe) -> nil
      not is_nil(finalized) and l1_block_number <= finalized -> :finalized
      not is_nil(safe) and l1_block_number <= safe -> :safe
      true -> :unsafe
    end
  end

  @doc """
    Returns what the output root page shows besides the root itself: the committed block range, the number
    of blocks and transactions in it, the L1 finality of the proposal, and the end of the challenge period.
  """
  @spec details(t(), [Chain.api?()]) :: %{
          l2_start_block_number: non_neg_integer() | nil,
          l2_end_block_number: non_neg_integer(),
          blocks_count: non_neg_integer() | nil,
          transactions_count: non_neg_integer() | nil,
          l1_finality: :finalized | :safe | :unsafe | nil,
          challenge_period_end: DateTime.t() | nil
        }
  def details(%__MODULE__{} = root, options \\ []) do
    {start_block, end_block} = block_range(root, options)

    {blocks_count, transactions_count} =
      if is_nil(start_block) do
        {nil, nil}
      else
        {max(end_block - start_block + 1, 0), transactions_count(start_block, end_block, options)}
      end

    challenge_period_end =
      case constant_integer(@finalization_period_constant, options) do
        nil -> nil
        period -> DateTime.add(root.l1_timestamp, period)
      end

    %{
      l2_start_block_number: start_block,
      l2_end_block_number: end_block,
      blocks_count: blocks_count,
      transactions_count: transactions_count,
      l1_finality: l1_finality(root.l1_block_number, options),
      challenge_period_end: challenge_period_end
    }
  end

  @doc """
    Lists consensus blocks numbered `first_block..last_block`, newest first. The `:paging_options` key
    `{block_number}` returns only blocks strictly below it.
  """
  @spec blocks_in_range(non_neg_integer(), non_neg_integer(), keyword()) :: [Block.t()]
  def blocks_in_range(first_block, last_block, options \\ []) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    paging_options = Keyword.get(options, :paging_options, default_paging_options())

    from(block in Block,
      where: block.consensus == true and block.number >= ^first_block and block.number <= ^last_block
    )
    |> page_blocks(paging_options)
    |> order_by(desc: :number)
    |> limit(^paging_options.page_size)
    |> join_associations(necessity_by_association)
    |> select_repo(options).all(timeout: :infinity)
  end

  @doc """
    Counts the rows of `query`, or returns `nil` when Postgres cancels the count after `timeout_ms`.
    `SET LOCAL statement_timeout` makes the server stop the query, so the connection is not held.
  """
  @spec count_within(Ecto.Queryable.t(), non_neg_integer(), [Chain.api?()]) :: non_neg_integer() | nil
  def count_within(query, timeout_ms, options \\ []) do
    repo = select_repo(options)

    {:ok, count} =
      repo.transaction(fn ->
        repo.query!("SET LOCAL statement_timeout = #{timeout_ms}")
        repo.aggregate(query, :count, timeout: :infinity)
      end)

    count
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :query_canceled, do: nil, else: reraise(error, __STACKTRACE__)
  end

  defp transactions_count(start_block, end_block, options) do
    from(transaction in Transaction,
      where:
        transaction.block_number >= ^start_block and transaction.block_number <= ^end_block and
          transaction.block_consensus == true
    )
    |> count_within(@transactions_count_timeout_ms, options)
  end

  defp page_blocks(query, %PagingOptions{key: {block_number}}), do: where(query, [block], block.number < ^block_number)
  defp page_blocks(query, _paging_options), do: query

  defp increment(nil), do: nil
  defp increment(number), do: number + 1

  defp constant_integer(key, options) do
    key
    |> Constants.get_constant_value(options)
    |> Helper.parse_integer()
  end

  defp page_output_roots(query, %PagingOptions{key: nil}), do: query

  defp page_output_roots(query, %PagingOptions{key: {index}}) do
    from(r in query, where: r.l2_output_index < ^index)
  end

  @doc """
    Forms a query to find the last Output Root's L1 block number and transaction hash.
    Used by the `Indexer.Fetcher.Optimism.OutputRoot` module.

    ## Returns
    - A query which can be used by the `Repo.one` function.
  """
  @spec last_root_l1_block_number_query() :: Ecto.Queryable.t()
  def last_root_l1_block_number_query do
    from(root in __MODULE__,
      select: {root.l1_block_number, root.l1_transaction_hash},
      order_by: [desc: root.l2_output_index],
      limit: 1
    )
  end

  @doc """
    Forms a query to remove all Output Roots related to the specified L1 block number.
    Used by the `Indexer.Fetcher.Optimism.OutputRoot` module.

    ## Parameters
    - `l1_block_number`: The L1 block number for which the Output Roots should be removed
                         from the `op_output_roots` database table.

    ## Returns
    - A query which can be used by the `delete_all` function.
  """
  @spec remove_roots_query(non_neg_integer()) :: Ecto.Queryable.t()
  def remove_roots_query(l1_block_number) do
    from(root in __MODULE__, where: root.l1_block_number == ^l1_block_number)
  end
end
