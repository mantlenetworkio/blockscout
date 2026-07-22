defmodule Explorer.Chain.CsvExport.AdvancedFilterTest do
  use Explorer.DataCase

  alias Explorer.Chain.AdvancedFilter
  alias Explorer.Chain.CsvExport.AdvancedFilter, as: AdvancedFilterCsvExporter

  describe "to_csv_format/1" do
    test "exports ERC-8056 UI amount metadata without replacing the raw token value" do
      token = insert(:token, type: "ERC-20", extensions: ["ERC-8056"], decimals: 18)
      transaction = insert(:transaction) |> with_block()

      insert(:token_transfer,
        transaction: transaction,
        token_contract_address: token.contract_address,
        token_type: "ERC-20",
        amount: Decimal.new("50000000000000000000"),
        ui_value: Decimal.new("150000000000000000000"),
        ui_multiplier: Decimal.new("3000000000000000000"),
        ui_amount_status: "ok"
      )

      [headers, row] =
        [transaction_types: ["ERC-20"], token_extension: "ERC-8056"]
        |> AdvancedFilter.list()
        |> AdvancedFilterCsvExporter.to_csv_format()
        |> Enum.to_list()

      csv_row = headers |> Enum.zip(row) |> Map.new()

      assert csv_row["TokenValue"] == "50.0"
      assert csv_row["TokenUIValue"] == "150.0"
      assert csv_row["TokenUIMultiplier"] == "3"
    end
  end
end
