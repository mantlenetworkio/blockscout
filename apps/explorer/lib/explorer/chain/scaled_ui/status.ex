defmodule Explorer.Chain.ScaledUi.Status do
  @moduledoc """
  Classifies an ERC-8056 UI amount against its raw amount and multiplier.
  """

  @scale 1_000_000_000_000_000_000
  @uint256_max Bitwise.bsl(1, 256) - 1

  @type t :: :ok | :overflow | :unknown | :mismatch | :event_missing

  @spec judge(Decimal.t(), Decimal.t() | nil, Decimal.t() | nil) :: t()
  def judge(_raw_amount, nil, _multiplier), do: :event_missing
  def judge(_raw_amount, _ui_value, nil), do: :unknown

  def judge(raw_amount, ui_value, multiplier) do
    raw_integer = Decimal.to_integer(raw_amount)
    ui_integer = Decimal.to_integer(ui_value)
    multiplier_integer = Decimal.to_integer(multiplier)
    product = raw_integer * multiplier_integer
    expected_ui_value = div(product, @scale)

    cond do
      expected_ui_value == ui_integer -> :ok
      ui_integer == 0 and (product > @uint256_max or expected_ui_value > @uint256_max) -> :overflow
      true -> :mismatch
    end
  end
end
