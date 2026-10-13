defmodule Explorer.Chain.Cache.OptimismFinalizationPeriodTest do
  use ExUnit.Case, async: true

  alias Explorer.Chain.Cache.OptimismFinalizationPeriod

  test "child_spec sets a TTL so on-chain changes of FINALIZATION_PERIOD_SECONDS are re-fetched" do
    assert %{start: {ConCache, :start_link, [params]}} = OptimismFinalizationPeriod.child_spec()

    assert params[:global_ttl] == :timer.minutes(5)
    assert params[:ttl_check_interval] == :timer.minutes(1)
  end
end
