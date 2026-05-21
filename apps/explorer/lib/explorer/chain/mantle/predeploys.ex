defmodule Explorer.Chain.Mantle.Predeploys do
  @moduledoc """
  Registry of known Mantle predeploy contracts whose on-chain metadata
  (`name()` / `symbol()` / `decimals()`) cannot be probed reliably by the
  generic ERC-20 metadata retriever, so we hardcode them here.

  Without this overlay, addresses like the L2 WETH at
  `0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111` get cataloged with `name = nil`
  and `symbol = nil`, which the frontend renders as "Unnamed token".

  Only ERC-20-shaped entries belong here. Non-token system predeploys
  (CrossDomainMessenger, L2ToL1MessagePasser, etc.) never reach the token
  fetcher pipeline anyway, so listing them would be inert — keep this map
  focused on token contracts.
  """

  alias Explorer.Chain.Hash

  @predeploys %{
    # L2 WETH on Mantle (MNT is the native gas token, ETH is represented as
    # a predeployed ERC-20 at this dead-looking address).
    "0xdeaddeaddeaddeaddeaddeaddeaddeaddead1111" => %{
      name: "Wrapped Ether",
      symbol: "WETH",
      decimals: Decimal.new(18)
    }
  }

  @predeploys_by_bytes Map.new(@predeploys, fn {hex, meta} ->
                         {:ok, %Hash{bytes: bytes}} = Hash.Address.cast(hex)
                         {bytes, meta}
                       end)

  @typedoc """
  Hardcoded ERC-20 metadata fields applied when the on-chain probe returns nil
  for them.
  """
  @type override :: %{
          required(:name) => String.t(),
          required(:symbol) => String.t(),
          required(:decimals) => Decimal.t()
        }

  @doc """
  Returns hardcoded metadata for the given address, or `nil` if the address
  isn't a registered Mantle predeploy.
  """
  @spec lookup(Hash.Address.t() | any()) :: override() | nil
  def lookup(%Hash{byte_count: 20, bytes: bytes}), do: Map.get(@predeploys_by_bytes, bytes)
  def lookup(_), do: nil
end
