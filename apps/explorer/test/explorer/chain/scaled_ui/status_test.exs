defmodule Explorer.Chain.ScaledUi.StatusTest do
  use ExUnit.Case, async: true

  alias Explorer.Chain.ScaledUi.Status

  @scale 1_000_000_000_000_000_000
  @uint256_max Bitwise.<<<(1, 256) - 1

  test "returns ok when the event value matches the exact scaled amount" do
    assert Status.judge(d(2), d(3), d(div(3 * @scale, 2))) == :ok
  end

  test "returns ok when integer division legally truncates to zero" do
    assert Status.judge(d(1), d(0), d(1)) == :ok
  end

  test "returns overflow for the zero sentinel after a uint256 intermediate overflow" do
    assert Status.judge(d(@uint256_max), d(0), d(@scale)) == :overflow
  end

  test "accepts a correct mulDiv result even when the intermediate product exceeds uint256" do
    assert Status.judge(d(@uint256_max), d(@uint256_max), d(@scale)) == :ok
  end

  test "returns mismatch for a non-sentinel incorrect event value" do
    assert Status.judge(d(2), d(4), d(@scale)) == :mismatch
  end

  test "returns unknown when the multiplier is unavailable" do
    assert Status.judge(d(2), d(2), nil) == :unknown
  end

  test "returns event_missing before considering multiplier availability" do
    assert Status.judge(d(2), nil, nil) == :event_missing
  end

  defp d(value), do: value |> Integer.to_string() |> Decimal.new()
end
