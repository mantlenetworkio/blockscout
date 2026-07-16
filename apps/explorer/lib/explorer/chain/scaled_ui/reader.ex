defmodule Explorer.Chain.ScaledUi.Reader do
  @moduledoc "Provides trusted ERC-8056 values for read paths."

  import Ecto.Query, only: [from: 2]

  alias Explorer.Chain.Block
  alias Explorer.Chain.ScaledUi.{Timeline, TokenState}

  @multiplier_scale Decimal.new("1000000000000000000")

  @spec canonical_head_timestamp(module()) :: Decimal.t()
  def canonical_head_timestamp(repo) do
    query =
      from(block in Block,
        where: block.consensus == true,
        order_by: [desc: block.number],
        limit: 1,
        select: block.timestamp
      )

    case repo.one(query) do
      %DateTime{} = timestamp -> timestamp |> DateTime.to_unix() |> Decimal.new()
      _ -> Decimal.new(0)
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
end
