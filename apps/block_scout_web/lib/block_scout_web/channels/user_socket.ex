defmodule BlockScoutWeb.UserSocket do
  use Phoenix.Socket
  use Absinthe.Phoenix.Socket, schema: BlockScoutWeb.GraphQL.Schema

  channel("addresses:*", BlockScoutWeb.AddressChannel)
  channel("blocks:*", BlockScoutWeb.BlockChannel)
  channel("exchange_rate:*", BlockScoutWeb.ExchangeRateChannel)
  channel("optimism_deposits:*", BlockScoutWeb.OptimismDepositChannel)
  channel("rewards:*", BlockScoutWeb.RewardChannel)
  # Prevent socket push temporary
  channel("transactions:*", BlockScoutWeb.TransactionChannel)
  channel("tokens:*", BlockScoutWeb.TokenChannel)
  channel("token_instances:*", BlockScoutWeb.TokenInstanceChannel)

  channel("mantle_deposits:*", BlockScoutWeb.MantleDepositChannel)

  def connect(%{"locale" => locale}, socket) do
    {:ok, assign(socket, :locale, locale)}
  end

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
