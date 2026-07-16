defmodule Explorer.Chain.ScaledUi.Reader do
  @moduledoc "Provides trusted ERC-8056 values for read paths."

  import Ecto.Query, only: [from: 2]

  alias Explorer.Chain.{Block, Hash, ScaledUiMultiplierUpdate}
  alias Explorer.Chain.ScaledUi.{Timeline, TokenState}

  @multiplier_scale Decimal.new("1000000000000000000")

  @spec canonical_head_timestamp(module()) :: Decimal.t()
  def canonical_head_timestamp(repo) do
    case repo.one(canonical_head_query()) do
      %{timestamp: timestamp} -> decimal_timestamp(timestamp)
      _no_canonical_head -> Decimal.new(0)
    end
  end

  @doc "Returns canonical multiplier events and their canonical head from one database snapshot."
  @spec canonical_multiplier_updates_snapshot(module(), Hash.Address.t()) ::
          {[ScaledUiMultiplierUpdate.t()], Decimal.t()}
  def canonical_multiplier_updates_snapshot(repo, token_contract_address_hash) do
    events_query =
      token_contract_address_hash
      |> ScaledUiMultiplierUpdate.canonical_by_token_query()
      |> Ecto.Query.exclude(:preload)

    query =
      from([update, block] in events_query,
        cross_join: head in subquery(canonical_head_query()),
        select: {update, block, head.timestamp}
      )

    case repo.all(query) do
      [] ->
        {[], Decimal.new(0)}

      [{_, _, head_timestamp} | _] = rows ->
        events = Enum.map(rows, fn {event, block, _head_timestamp} -> %{event | block: block} end)
        {events, decimal_timestamp(head_timestamp)}
    end
  end

  @spec current_multiplier(TokenState.t() | map() | nil, Decimal.t()) :: {:ok, Decimal.t()} | :unknown
  def current_multiplier(state, head_timestamp), do: Timeline.current_multiplier(state, head_timestamp)

  @spec scaled_amount(Decimal.t() | nil, TokenState.t() | map() | nil, Decimal.t()) :: Decimal.t() | nil
  def scaled_amount(nil, _state, _head_timestamp), do: nil

  def scaled_amount(amount, state, head_timestamp) do
    case current_multiplier(state, head_timestamp) do
      {:ok, multiplier} ->
        amount
        |> Decimal.mult(multiplier)
        |> Decimal.div(@multiplier_scale)
        |> Decimal.round(0, :floor)

      :unknown ->
        nil
    end
  end

  @spec pending_schedule(TokenState.t() | map(), Decimal.t()) :: {Decimal.t(), Decimal.t()} | nil
  def pending_schedule(state, head_timestamp) do
    case {Map.get(state, :pending_multiplier), Map.get(state, :pending_effective_at)} do
      {%Decimal{} = multiplier, %Decimal{} = effective_at} ->
        if Decimal.compare(effective_at, head_timestamp) == :gt, do: {multiplier, effective_at}

      _ ->
        nil
    end
  end

  defp canonical_head_query do
    from(block in Block,
      where: block.consensus == true,
      order_by: [desc: block.number],
      limit: 1,
      select: %{timestamp: block.timestamp}
    )
  end

  defp decimal_timestamp(%DateTime{} = timestamp), do: timestamp |> DateTime.to_unix() |> Decimal.new()
  defp decimal_timestamp(_timestamp), do: Decimal.new(0)
end
