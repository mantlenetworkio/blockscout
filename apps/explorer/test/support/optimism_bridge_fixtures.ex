defmodule Explorer.OptimismBridgeFixtures do
  @moduledoc """
  Real Mantle bridge messages (`fixture/optimism/bridge_messages.json`: Mantle Sepolia, plus one mainnet wstETH
  withdrawal) together with the transfer viem decodes from each, used as test vectors for bridge decoding.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @path Path.join(__DIR__, "fixture/optimism/bridge_messages.json")
  @external_resource @path
  @fixtures @path |> File.read!() |> Jason.decode!()

  @bridges %{
    sepolia: [
      l1_cross_domain_messenger: "0x37dac5312e31adb8bb0802fc72ca84da5cdfcb4c",
      l1_standard_bridge: "0x21f308067241b2028503c07bd7cb3751ffab0fb2"
    ],
    mainnet: [
      l1_cross_domain_messenger: "0x676a795fe6e43c17c668de16730c3f690feb7120",
      l1_standard_bridge: "0x95fc37a27a2f68e3a647cdc081f0a89bb47c3012",
      l1_wst_bridge: "0x2d001d79e5af5f65a939781fe228b267a8ed468b",
      l2_wst_bridge: "0x9c46560d6209743968cc24150893631a39afde4d"
    ]
  }

  @transfer_keys ~w(message_hash transfer_type transfer_from_address_hash transfer_to_address_hash l1_token_address_hash
                    l2_token_address_hash transfer_amount mnt_value eth_value)a

  @doc "A deposit fixture: `l2_transaction_hash`, `l2_transaction_from`, `l2_transaction_input`, `l1_event`, `expected`."
  def deposit(name), do: Map.fetch!(@fixtures["deposits"], to_string(name))

  @doc "A withdrawal fixture: `l2_transaction_hash`, `l2_block_number`, `message_passed`, `expected`."
  def withdrawal(name), do: Map.fetch!(@fixtures["withdrawals"], to_string(name))

  @doc "The transfer viem decodes from a fixture, in the shape `stored_transfer/1` returns."
  def expected_transfer(%{"expected" => expected}) do
    Map.new(@transfer_keys, fn key ->
      value = expected[Atom.to_string(key)]

      cond do
        is_nil(value) -> {key, nil}
        key == :transfer_type -> {key, String.to_existing_atom(value)}
        key in [:transfer_amount, :mnt_value, :eth_value] -> {key, String.to_integer(value)}
        true -> {key, value}
      end
    end)
  end

  @doc "The transfer columns of an `op_deposits` / `op_withdrawals` row: hashes as strings, numbers as integers."
  def stored_transfer(row) do
    Map.new(@transfer_keys, fn key ->
      value =
        case Map.fetch!(row, key) do
          %Decimal{} = decimal -> Decimal.to_integer(decimal)
          value when is_atom(value) -> value
          value -> to_string(value)
        end

      {key, value}
    end)
  end

  @doc """
  Configures Mantle mode with the messenger and bridges of Mantle Sepolia (`:sepolia`) or mainnet (`:mainnet`, which
  also has the wstETH bridges) for the calling test, and restores the previous configuration when it exits.
  """
  def configure_bridges(network \\ :sepolia) do
    {messenger, bridges} = Keyword.pop!(@bridges[network], :l1_cross_domain_messenger)
    defaults = [mantle_mode: true, l2_standard_bridge: nil, l1_wst_bridge: nil, l2_wst_bridge: nil]

    put_indexer_env(Indexer.Fetcher.Optimism, Keyword.merge(defaults, bridges))
    put_indexer_env(Indexer.Fetcher.Optimism.MessageRelayL1, l1_cross_domain_messenger: messenger)
  end

  defp put_indexer_env(key, values) do
    previous = Application.get_env(:indexer, key)
    Application.put_env(:indexer, key, Keyword.merge(previous || [], values))
    on_exit(fn -> Application.put_env(:indexer, key, previous) end)
  end
end
