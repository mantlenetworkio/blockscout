defmodule Explorer.Etherscan.Contracts do
  @moduledoc """
  This module contains functions for working with contracts, as they pertain to the
  `Explorer.Etherscan` context.

  """

  import Ecto.Query,
    only: [
      from: 2,
      where: 3
    ]

  alias Explorer.Repo
  alias Explorer.Chain.{Address, Hash, SmartContract, Transaction, Block, InternalTransaction}
  alias Explorer.Chain.SmartContract.Proxy
  alias Explorer.Chain.SmartContract.Proxy.EIP1167

  @doc """
    Returns address with preloaded SmartContract and proxy info if it exists
  """
  @spec address_hash_to_address_with_source_code(Hash.Address.t()) :: Address.t() | nil
  def address_hash_to_address_with_source_code(address_hash, twin_needed? \\ true) do
    result =
      case Repo.replica().get(Address, address_hash) do
        nil ->
          nil

        address ->
          address_with_smart_contract =
            Repo.replica().preload(address, [
              [smart_contract: :smart_contract_additional_sources],
              :decompiled_smart_contracts
            ])

          if address_with_smart_contract.smart_contract do
            formatted_code = format_source_code_output(address_with_smart_contract.smart_contract)

            %{
              address_with_smart_contract
              | smart_contract: %{address_with_smart_contract.smart_contract | contract_source_code: formatted_code}
            }
          else
            address_verified_twin_contract =
              EIP1167.get_implementation_address(address_hash) || maybe_fetch_twin(twin_needed?, address_hash)

            compose_address_with_smart_contract(
              address_with_smart_contract,
              address_verified_twin_contract
            )
          end
      end

    result
    |> append_proxy_info()
  end

  defp maybe_fetch_twin(twin_needed?, address_hash),
    do: if(twin_needed?, do: SmartContract.get_address_verified_twin_contract(address_hash).verified_contract)

  defp compose_address_with_smart_contract(address_with_smart_contract, address_verified_twin_contract) do
    if address_verified_twin_contract do
      formatted_code = format_source_code_output(address_verified_twin_contract)

      %{
        address_with_smart_contract
        | smart_contract: %{address_verified_twin_contract | contract_source_code: formatted_code}
      }
    else
      address_with_smart_contract
    end
  end

  def append_proxy_info(%Address{smart_contract: smart_contract} = address) when not is_nil(smart_contract) do
    updated_smart_contract =
      if Proxy.proxy_contract?(smart_contract) do
        smart_contract
        |> Map.put(:is_proxy, true)
        |> Map.put(
          :implementation_address_hash_string,
          smart_contract
          |> SmartContract.get_implementation_address_hash()
          |> Tuple.to_list()
          |> List.first()
        )
      else
        smart_contract
        |> Map.put(:is_proxy, false)
      end

    address
    |> Map.put(:smart_contract, updated_smart_contract)
  end

  def append_proxy_info(address), do: address

  def list_verified_contracts(limit, offset, opts) do
    query =
      from(
        smart_contract in SmartContract,
        order_by: [asc: smart_contract.inserted_at],
        left_join: addr in assoc(smart_contract, :address),
        join: txn in Transaction,
        on: addr.hash == txn.created_contract_address_hash,
        left_join: in_txn in InternalTransaction,
        on: addr.hash == in_txn.created_contract_address_hash,
        left_join: block in Block,
        on: txn.block_number == block.number or in_txn.block_number == block.number,
        limit: ^limit,
        offset: ^offset,
        preload: [:address],
        select: %{
          smart_contract: smart_contract,
          transaction: %{
            creation_hash: coalesce(txn.hash, in_txn.transaction_hash),
            creation_timestamp: block.timestamp
          }
        }
      )

    verified_at_start_timestamp_exist? = Map.has_key?(opts, :verified_at_start_timestamp)
    verified_at_end_timestamp_exist? = Map.has_key?(opts, :verified_at_end_timestamp)

    query_in_timestamp_range =
      cond do
        verified_at_start_timestamp_exist? && verified_at_end_timestamp_exist? ->
          query
          |> where([smart_contract], smart_contract.inserted_at >= ^opts.verified_at_start_timestamp)
          |> where([smart_contract], smart_contract.inserted_at < ^opts.verified_at_end_timestamp)

        verified_at_start_timestamp_exist? ->
          query
          |> where([smart_contract], smart_contract.inserted_at >= ^opts.verified_at_start_timestamp)

        verified_at_end_timestamp_exist? ->
          query
          |> where([smart_contract], smart_contract.inserted_at < ^opts.verified_at_end_timestamp)

        true ->
          query
      end

    query_in_timestamp_range
    |> Repo.replica().all()
    |> Enum.map(fn smart_contract ->
      %{
        address: Map.put(smart_contract.smart_contract.address, :smart_contract, smart_contract.smart_contract),
        transaction: %{
          creation_hash: smart_contract.transaction.creation_hash,
          creation_timestamp: smart_contract.transaction.creation_timestamp
        }
      }
    end)
  end

  def list_decompiled_contracts(limit, offset, not_decompiled_with_version \\ nil) do
    query =
      from(
        address in Address,
        where: address.contract_code != <<>>,
        where: not is_nil(address.contract_code),
        where: address.decompiled == true,
        left_join: txn in Transaction,
        on: address.hash == txn.created_contract_address_hash,
        left_join: in_txn in InternalTransaction,
        on: address.hash == in_txn.created_contract_address_hash,
        left_join: block in Block,
        on: txn.block_number == block.number or in_txn.block_number == block.number,
        limit: ^limit,
        offset: ^offset,
        order_by: [asc: address.inserted_at],
        preload: [:smart_contract],
        select: %{
          address: address,
          transaction: %{
            creation_hash: coalesce(txn.hash, in_txn.transaction_hash),
            creation_timestamp: block.timestamp
          }
        }
      )

    query
    |> reject_decompiled_with_version(not_decompiled_with_version)
    |> Repo.replica().all()
  end

  def list_unordered_unverified_contracts(limit, offset) do
    query =
      from(
        address in Address,
        where: address.contract_code != <<>>,
        where: not is_nil(address.contract_code),
        where: fragment("? IS NOT TRUE", address.verified),
        left_join: txn in Transaction,
        on: address.hash == txn.created_contract_address_hash,
        left_join: in_txn in InternalTransaction,
        on: address.hash == in_txn.created_contract_address_hash,
        left_join: block in Block,
        on: txn.block_number == block.number or in_txn.block_number == block.number,
        limit: ^limit,
        offset: ^offset,
        select: %{
          address: address,
          transaction: %{
            creation_hash: coalesce(txn.hash, in_txn.transaction_hash),
            creation_timestamp: block.timestamp
          }
        }
      )

    query
    |> Repo.replica().all()
    |> Enum.map(fn address ->
      %{
        address: %{ address.address | smart_contract: nil},
        transaction: %{
          creation_hash: address.transaction.creation_hash,
          creation_timestamp: address.transaction.creation_timestamp
        }
      }
    end)
  end

  def list_unordered_not_decompiled_contracts(limit, offset) do
    query =
      from(
        address in Address,
        where: fragment("? IS NOT TRUE", address.verified),
        where: fragment("? IS NOT TRUE", address.decompiled),
        where: address.contract_code != <<>>,
        where: not is_nil(address.contract_code),
        left_join: txn in Transaction,
        on: address.hash == txn.created_contract_address_hash,
        left_join: in_txn in InternalTransaction,
        on: address.hash == in_txn.created_contract_address_hash,
        left_join: block in Block,
        on: txn.block_number == block.number or in_txn.block_number == block.number,
        limit: ^limit,
        offset: ^offset,
        select: %{
          address: address,
          transaction: %{
            creation_hash: coalesce(txn.hash, in_txn.transaction_hash),
            creation_timestamp: block.timestamp
          }
        }
      )

    query
    |> Repo.replica().all()
    |> Enum.map(fn address ->
      %{
        address: %{ address.address | smart_contract: nil},
        transaction: %{
          creation_hash: address.transaction.creation_hash,
          creation_timestamp: address.transaction.creation_timestamp
        }
      }
    end)
  end

  def list_empty_contracts(limit, offset) do
    query =
      from(address in Address,
        where: address.contract_code == <<>>,
        preload: [:smart_contract, :decompiled_smart_contracts],
        left_join: txn in Transaction,
        on: address.hash == txn.created_contract_address_hash,
        left_join: in_txn in InternalTransaction,
        on: address.hash == in_txn.created_contract_address_hash,
        left_join: block in Block,
        on: txn.block_number == block.number or in_txn.block_number == block.number,
        order_by: [asc: address.inserted_at],
        limit: ^limit,
        offset: ^offset,
        select: %{
          address: address,
          transaction: %{
            creation_hash: coalesce(txn.hash, in_txn.transaction_hash),
            creation_timestamp: block.timestamp
          }
        }
      )

    Repo.replica().all(query)
  end

  def list_contracts(limit, offset) do
    query =
      from(
        address in Address,
        where: not is_nil(address.contract_code),
        left_join: txn in Transaction,
        on: address.hash == txn.created_contract_address_hash,
        left_join: in_txn in InternalTransaction,
        on: address.hash == in_txn.created_contract_address_hash,
        left_join: block in Block,
        on: txn.block_number == block.number or in_txn.block_number == block.number,
        preload: [:smart_contract],
        order_by: [asc: address.inserted_at],
        limit: ^limit,
        offset: ^offset,
        select: %{
          address: address,
          transaction: %{
            creation_hash: coalesce(txn.hash, in_txn.transaction_hash),
            creation_timestamp: block.timestamp
          }
        }
      )

    Repo.replica().all(query)
  end

  def list_not_empty_contracts(limit, offset) do
    query =
      from(
        address in Address,
        where: not is_nil(address.contract_code),
        left_join: txn in Transaction,
        on: address.hash == txn.created_contract_address_hash,
        left_join: in_txn in InternalTransaction,
        on: address.hash == in_txn.created_contract_address_hash,
        left_join: block in Block,
        on: txn.block_number == block.number or in_txn.block_number == block.number,
        preload: [:smart_contract],
        order_by: [asc: address.inserted_at],
        limit: ^limit,
        offset: ^offset,
        where: not is_nil(coalesce(txn.created_contract_address_hash, in_txn.created_contract_address_hash)),
        select: %{
          address: address,
          transaction: %{
            creation_hash: coalesce(txn.hash, in_txn.transaction_hash),
            creation_timestamp: block.timestamp
          }
        }
      )

    Repo.replica().all(query)
  end

  defp format_source_code_output(smart_contract), do: smart_contract.contract_source_code

  defp reject_decompiled_with_version(query, nil), do: query

  defp reject_decompiled_with_version(query, reject_version) do
    from(
      address in query,
      left_join: decompiled_smart_contract in assoc(address, :decompiled_smart_contracts),
      on: decompiled_smart_contract.decompiler_version == ^reject_version,
      where: is_nil(decompiled_smart_contract.address_hash)
    )
  end
end
