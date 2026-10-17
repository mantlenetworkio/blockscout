defmodule Explorer.Migrator.OptimismBridgeTransfers do
  @moduledoc """
    Shared by the `OptimismDepositTransfers` and `OptimismWithdrawalTransfers` background migrations: picks the rows
    to decode and writes the decoded bridge transfers, with one statement per batch.
  """

  require Logger

  alias Explorer.Repo

  @typedoc """
    How a backfill reads its table:
    - `:undecoded` - `(cursor, limit)` returns the keys of the undecoded rows after `cursor` (`nil` for the first),
      in key order.
    - `:decodable` - the same, for the undecoded rows whose source data is indexed by now.
    - `:undecoded_count` - `()` returns the number of undecoded rows.
    - `:cursor` - `(key)` returns the cursor after `key`, a JSON value kept in the migration state.
    - `:limit`, `:retries`, `:retry_interval` (milliseconds) and `:name` (used in the log).
  """
  @type source :: keyword()

  @transfer_columns ~w(message_hash transfer_type transfer_from_address_hash transfer_to_address_hash
                       l1_token_address_hash l2_token_address_hash transfer_amount mnt_value eth_value)
  @transfer_types ~w(bytea text bytea bytea bytea bytea numeric numeric numeric)

  @doc """
    Returns the next keys to decode and the new migration state, or no keys when the backfill is over.

    The backfill first passes over every undecoded row. A row whose source data is not indexed yet (the L2 transaction
    of a deposit, the `MessagePassed` log of a withdrawal) stays undecoded, and nothing else would ever decode it. So
    rounds over the rows decodable by now follow, `retry_interval` apart, until no row is left undecoded. A round that
    decodes rows resets the count; `retries` rounds in a row without progress end the backfill, and what stays
    undecoded is logged.
  """
  @spec next_batch(map(), source()) :: {[term()], map()}
  def next_batch(%{"retrying" => true} = state, source) do
    case source[:decodable].(state["cursor"], source[:limit]) do
      [] -> end_round(state, source)
      keys -> {keys, Map.put(state, "cursor", source[:cursor].(List.last(keys)))}
    end
  end

  def next_batch(state, source) do
    case source[:undecoded].(state["cursor"], source[:limit]) do
      [] -> next_batch(%{"retrying" => true}, source)
      keys -> {keys, Map.put(state, "cursor", source[:cursor].(List.last(keys)))}
    end
  end

  defp end_round(state, source) do
    undecoded = source[:undecoded_count].()

    idle_rounds =
      if is_integer(state["undecoded"]) and undecoded >= state["undecoded"],
        do: Map.get(state, "idle_rounds", 0) + 1,
        else: 0

    cond do
      undecoded == 0 ->
        {[], state}

      idle_rounds >= source[:retries] ->
        Logger.warning("#{source[:name]}: #{undecoded} row(s) stay undecoded, their source data is not indexed")
        {[], state}

      true ->
        :timer.sleep(source[:retry_interval])
        next_batch(%{"retrying" => true, "undecoded" => undecoded, "idle_rounds" => idle_rounds}, source)
    end
  end

  @doc """
    Updates the rows of `table` matching the keys of `transfers`, a list of `{key_values, transfer}` with
    `transfer` as returned by `Explorer.Chain.Optimism.BridgeMessage`. `keys` names the key columns and their SQL
    types, in the order of `key_values`. Rows that already have a transfer (the indexer decoded them meanwhile) are left
    alone, and so are empty transfers.
  """
  @spec update([{[term()], map()}], String.t(), [{String.t(), String.t()}]) :: :ok
  def update(transfers, table, keys) do
    case Enum.reject(transfers, fn {_key_values, transfer} -> transfer == %{} end) do
      [] ->
        :ok

      transfers ->
        Repo.query!(update_statement(table, keys), params(transfers), timeout: :infinity)
        :ok
    end
  end

  defp update_statement(table, keys) do
    key_count = length(keys)
    key_names = Enum.map(0..(key_count - 1), &"key#{&1}")
    arrays = Enum.map(keys, &elem(&1, 1)) ++ @transfer_types

    """
    UPDATE #{table} AS t
    SET #{Enum.map_join(@transfer_columns, ", ", &set_column/1)}, updated_at = $#{length(arrays) + 1}
    FROM unnest(#{arrays |> Enum.with_index(1) |> Enum.map_join(", ", fn {type, i} -> "$#{i}::#{type}[]" end)})
      AS v(#{Enum.join(key_names ++ @transfer_columns, ", ")})
    WHERE #{keys |> Enum.zip(key_names) |> Enum.map_join(" AND ", fn {{column, _type}, name} -> "t.#{column} = v.#{name}" end)}
      AND t.transfer_type IS NULL
    """
  end

  defp set_column("transfer_type"), do: "transfer_type = v.transfer_type::op_bridge_transfer_type"
  defp set_column(column), do: "#{column} = v.#{column}"

  # One array per key column and per transfer column, then the update time
  defp params(transfers) do
    columns =
      transfers
      |> Enum.map(fn {key_values, transfer} ->
        key_values ++
          [
            bytes(transfer.message_hash),
            Atom.to_string(transfer.transfer_type),
            bytes(transfer.transfer_from_address_hash),
            bytes(transfer.transfer_to_address_hash),
            bytes(transfer.l1_token_address_hash),
            bytes(transfer.l2_token_address_hash),
            decimal(transfer.transfer_amount),
            decimal(transfer.mnt_value),
            decimal(transfer.eth_value)
          ]
      end)
      |> Enum.zip_with(& &1)

    columns ++ [DateTime.utc_now()]
  end

  defp bytes(nil), do: nil
  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :mixed)

  defp decimal(nil), do: nil
  defp decimal(value), do: Decimal.new(value)
end
