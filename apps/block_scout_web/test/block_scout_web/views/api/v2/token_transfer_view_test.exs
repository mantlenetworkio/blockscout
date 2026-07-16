defmodule BlockScoutWeb.API.V2.TokenTransferViewTest do
  use BlockScoutWeb.ConnCase, async: true

  alias BlockScoutWeb.API.V2.TokenTransferView
  alias Explorer.Chain.TokenTransfer

  describe "prepare_token_transfer_total/1" do
    test "returns value and decimals for ERC-20 transfer" do
      token = build(:token, type: "ERC-20", decimals: 18)

      token_transfer = %TokenTransfer{
        token: token,
        token_type: "ERC-20",
        amount: Decimal.new(1000),
        amounts: nil,
        token_ids: nil,
        token_instance: nil
      }

      result = TokenTransferView.prepare_token_transfer_total(token_transfer)

      assert Decimal.equal?(result["value"], Decimal.new(1000))
      assert result["decimals"] == 18
      refute Map.has_key?(result, "scaled_ui")
    end

    test "returns a complete scaled UI object for an annotated transfer" do
      token_transfer =
        erc20_transfer(
          ui_value: Decimal.new(2000),
          ui_multiplier: Decimal.new(2_000_000_000_000_000_000),
          ui_amount_status: "ok"
        )

      result = TokenTransferView.prepare_token_transfer_total(token_transfer)

      assert result["scaled_ui"] == %{
               "multiplier" => Decimal.new(2_000_000_000_000_000_000),
               "multiplier_decimals" => 18,
               "status" => "ok",
               "value" => Decimal.new(2000)
             }
    end

    test "keeps an unknown transfer visible without a multiplier" do
      token_transfer = erc20_transfer(ui_value: Decimal.new(2000), ui_amount_status: "unknown")

      result = TokenTransferView.prepare_token_transfer_total(token_transfer)

      assert result["scaled_ui"]["value"] == Decimal.new(2000)
      assert result["scaled_ui"]["multiplier"] == nil
      assert result["scaled_ui"]["status"] == "unknown"
    end

    test "returns the known multiplier when the UI amount event is missing" do
      token_transfer =
        erc20_transfer(
          ui_multiplier: Decimal.new(2_000_000_000_000_000_000),
          ui_amount_status: "event_missing"
        )

      result = TokenTransferView.prepare_token_transfer_total(token_transfer)

      assert result["scaled_ui"]["value"] == nil
      assert result["scaled_ui"]["multiplier"] == Decimal.new(2_000_000_000_000_000_000)
      assert result["scaled_ui"]["status"] == "event_missing"
    end

    test "returns token_id for ERC-721 transfer" do
      token = build(:token, type: "ERC-721")

      token_transfer = %TokenTransfer{
        token: token,
        token_type: "ERC-721",
        amount: nil,
        amounts: nil,
        token_ids: [42],
        token_instance: nil
      }

      result = TokenTransferView.prepare_token_transfer_total(token_transfer)

      assert result["token_id"] == 42
      assert Map.has_key?(result, "token_instance")
    end

    test "returns token_id, value and decimals for ERC-1155 transfer" do
      token = build(:token, type: "ERC-1155", decimals: 0)

      token_transfer = %TokenTransfer{
        token: token,
        token_type: "ERC-1155",
        amount: Decimal.new(5),
        amounts: nil,
        token_ids: [99],
        token_instance: nil
      }

      result = TokenTransferView.prepare_token_transfer_total(token_transfer)

      assert result["token_id"] == 99
      assert Decimal.equal?(result["value"], Decimal.new(5))
      assert result["decimals"] == 0
      assert Map.has_key?(result, "token_instance")
    end
  end

  defp erc20_transfer(attrs) do
    defaults = %{
      amount: Decimal.new(1000),
      amounts: nil,
      token: build(:token, type: "ERC-20", decimals: 18),
      token_ids: nil,
      token_instance: nil,
      token_type: "ERC-20"
    }

    struct!(TokenTransfer, Map.merge(defaults, Map.new(attrs)))
  end
end
