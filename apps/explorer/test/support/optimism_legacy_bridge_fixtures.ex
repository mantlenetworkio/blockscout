defmodule Explorer.OptimismLegacyBridgeFixtures do
  @moduledoc """
  Real Mantle v1 (pre-Bedrock) bridge messages (`fixture/optimism/legacy_bridge_messages.json`) with the identities the
  migration gave them, every migrated withdrawal hash checked on chain with `L2ToL1MessagePasser.sentMessages`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Explorer.Chain.Optimism.LegacyBridgeTransfer
  alias Explorer.Repo

  @path Path.join(__DIR__, "fixture/optimism/legacy_bridge_messages.json")
  @external_resource @path
  @fixtures @path |> File.read!() |> Jason.decode!()

  @keys ~w(message_hash transfer_type transfer_from_address_hash transfer_to_address_hash l1_token_address_hash
           l2_token_address_hash transfer_amount migrated_withdrawal_hash migrated_message_hash migrated_msg_data
           migrated_gas_limit)a

  @doc "A v1 withdrawal fixture: `network`, `sent_message` (the L2 log) and `expected`."
  def legacy_withdrawal(name), do: Map.fetch!(@fixtures["withdrawals"], to_string(name))

  @doc "A v1 deposit fixture: `network`, `sent_message` (the L1 log), `relay` (its L2 relay) and `expected`."
  def legacy_deposit(name), do: Map.fetch!(@fixtures["deposits"], to_string(name))

  @doc "The expected decoding of a fixture: hashes and addresses as 0x strings, numbers as integers, the type an atom."
  def expected_legacy(%{"expected" => expected}) do
    @keys
    |> Enum.filter(&Map.has_key?(expected, Atom.to_string(&1)))
    |> Map.new(fn key ->
      value = expected[Atom.to_string(key)]

      cond do
        is_nil(value) -> {key, nil}
        key == :transfer_type -> {key, String.to_existing_atom(value)}
        key in [:transfer_amount, :migrated_gas_limit] -> {key, String.to_integer(value)}
        true -> {key, value}
      end
    end)
  end

  @doc """
  Inserts a fixture as a backfilled v1 row of `mantle_legacy_bridge_transfers`, with its expected decoding and the given
  overrides (e.g. `transfer_from_address_hash`), and returns the stored row.
  """
  def insert_legacy(direction, name, overrides \\ %{}) do
    fixture = if direction == :deposit, do: legacy_deposit(name), else: legacy_withdrawal(name)
    log = fixture["sent_message"]
    nonce = legacy_nonce(fixture)

    row =
      fixture
      |> expected_legacy()
      |> Map.merge(%{
        direction: direction,
        nonce: nonce,
        transaction_hash: log["transactionHash"],
        block_number: String.to_integer(String.trim_leading(log["blockNumber"], "0x"), 16),
        timestamp: DateTime.utc_now()
      })
      |> Map.merge(Map.new(overrides))

    LegacyBridgeTransfer.upsert_all([row])
    Repo.get_by!(LegacyBridgeTransfer, direction: direction, nonce: row.nonce)
  end

  @doc "The legacy messenger nonce of a fixture, read from its `SentMessage` data."
  def legacy_nonce(%{"sent_message" => %{"data" => "0x" <> data}}) do
    data |> String.slice(128, 64) |> String.to_integer(16)
  end

  @doc """
  Configures the messenger and standard bridges of a fixture's network (`"sepolia"` or `"mainnet"`) and Mantle mode for
  the calling test, restoring the previous configuration when it exits.
  """
  def configure_legacy_bridges(network) do
    %{"l1_cross_domain_messenger" => messenger, "l1_standard_bridge" => l1_standard_bridge} =
      @fixtures["networks"][to_string(network)]

    put_indexer_env(Indexer.Fetcher.Optimism,
      mantle_mode: true,
      l1_standard_bridge: l1_standard_bridge,
      l2_standard_bridge: nil,
      l1_wst_bridge: nil,
      l2_wst_bridge: nil
    )

    put_indexer_env(Indexer.Fetcher.Optimism.MessageRelayL1, l1_cross_domain_messenger: messenger)
  end

  defp put_indexer_env(key, values) do
    previous = Application.get_env(:indexer, key)
    Application.put_env(:indexer, key, Keyword.merge(previous || [], values))
    on_exit(fn -> Application.put_env(:indexer, key, previous) end)
  end
end
