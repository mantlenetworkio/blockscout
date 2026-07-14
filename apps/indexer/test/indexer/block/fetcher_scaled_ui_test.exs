defmodule Indexer.Block.FetcherScaledUiTest do
  use ExUnit.Case, async: true

  alias Indexer.Block.Fetcher

  test "adds ERC-8056 only to token params with an in-batch capability event" do
    tokens = [
      %{contract_address_hash: "0x01", extensions: ["ERC-7802"]},
      %{contract_address_hash: "0x02"}
    ]

    capability_rows = [%{token_contract_address_hash: "0x01", capability_block: 10}]

    assert [matched, unmatched] = Fetcher.merge_scaled_ui_extensions(tokens, capability_rows)
    assert MapSet.new(matched.extensions) == MapSet.new(["ERC-7802", "ERC-8056"])
    refute Map.has_key?(unmatched, :extensions)
  end
end
