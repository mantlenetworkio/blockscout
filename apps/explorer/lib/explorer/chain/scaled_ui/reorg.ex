defmodule Explorer.Chain.ScaledUi.Reorg do
  @moduledoc "Restores ERC-8056 derived state after blocks lose consensus."

  import Ecto.Query, only: [from: 2]

  alias Explorer.Chain.{Block, Hash, Log, ScaledUiMultiplierUpdate, TokenTransfer}
  alias Explorer.Chain.ScaledUi.{Events, TokenState}

  @spec rollback(module(), [{integer(), Hash.Full.t()}], keyword()) ::
          {:ok, %{addresses: [Hash.Address.t()], removed_token_hashes: [Hash.Address.t()]}}
  def rollback(_repo, [], _options), do: {:ok, %{addresses: [], removed_token_hashes: []}}

  def rollback(repo, non_consensus_blocks, options) do
    timeout = Keyword.get(options, :timeout, 60_000)
    block_hashes = Enum.map(non_consensus_blocks, fn {_number, hash} -> hash end)
    topics = event_topics()

    affected_token_hashes = affected_token_hashes(repo, block_hashes, topics, timeout)
    addresses = affected_transfer_addresses(repo, block_hashes, timeout)

    repo.delete_all(
      from(event in ScaledUiMultiplierUpdate, where: event.block_hash in ^block_hashes),
      timeout: timeout
    )

    capability_rows = canonical_capability_rows(repo, affected_token_hashes, topics, timeout)

    {:ok, removed_token_hashes} =
      TokenState.replace_capabilities(repo, affected_token_hashes, capability_rows, timeout: timeout)

    {:ok, %{addresses: addresses, removed_token_hashes: removed_token_hashes}}
  end

  defp affected_token_hashes(repo, block_hashes, topics, timeout) do
    timeline_hashes =
      repo.all(
        from(event in ScaledUiMultiplierUpdate,
          where: event.block_hash in ^block_hashes,
          select: event.token_contract_address_hash,
          distinct: true
        ),
        timeout: timeout
      )

    log_hashes =
      repo.all(
        from(log in Log,
          where: log.block_hash in ^block_hashes and log.first_topic in ^topics,
          select: log.address_hash,
          distinct: true
        ),
        timeout: timeout
      )

    (timeline_hashes ++ log_hashes)
    |> Enum.uniq()
    |> Enum.sort_by(&hash_sort_key/1)
  end

  defp affected_transfer_addresses(repo, block_hashes, timeout) do
    repo.all(
      from(transfer in TokenTransfer,
        where: transfer.block_hash in ^block_hashes,
        where: not is_nil(transfer.ui_amount_status),
        select: {transfer.from_address_hash, transfer.to_address_hash}
      ),
      timeout: timeout
    )
    |> Enum.flat_map(fn {from, to} -> [from, to] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp canonical_capability_rows(_repo, [], _topics, _timeout), do: []

  defp canonical_capability_rows(repo, token_hashes, topics, timeout) do
    repo.all(
      from(log in Log,
        join: block in Block,
        on: block.hash == log.block_hash,
        where: block.consensus,
        where: log.address_hash in ^token_hashes and log.first_topic in ^topics,
        group_by: log.address_hash,
        select: %{
          token_contract_address_hash: log.address_hash,
          capability_block: min(log.block_number)
        }
      ),
      timeout: timeout
    )
  end

  defp event_topics do
    Enum.map(Events.all_topics(), fn topic ->
      {:ok, hash} = Hash.Full.cast(topic)
      hash
    end)
  end

  defp hash_sort_key(%Hash{bytes: bytes}), do: bytes
end
