defmodule Indexer.Fetcher.Token do
  @moduledoc """
  Fetches information about a token.
  """

  use Indexer.Fetcher, restart: :permanent
  use Spandex.Decorators

  alias Explorer.Chain
  alias Explorer.Chain.Hash.Address
  alias Explorer.Chain.Mantle.Predeploys
  alias Explorer.Chain.Token
  alias Explorer.MicroserviceInterfaces.MultichainSearch
  alias Explorer.Token.MetadataRetriever
  alias Indexer.{BufferedTask, Tracer}

  @behaviour BufferedTask

  @default_max_concurrency 10

  @doc false
  def child_spec([init_options, gen_server_options]) do
    {state, mergeable_init_options} = Keyword.pop(init_options, :json_rpc_named_arguments)

    if !state do
      raise ArgumentError,
            ":json_rpc_named_arguments must be provided to `#{__MODULE__}.child_spec " <>
              "to allow for json_rpc calls when running."
    end

    merged_init_opts =
      defaults()
      |> Keyword.merge(mergeable_init_options)
      |> Keyword.put(:state, state)

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial_acc, reducer, _) do
    {:ok, acc} =
      Chain.stream_uncataloged_token_contract_address_hashes(
        initial_acc,
        fn address, acc ->
          reducer.(address, acc)
        end,
        true
      )

    acc
  end

  @impl BufferedTask
  @decorate trace(name: "fetch", resource: "Indexer.Fetcher.Token.run/2", service: :indexer, tracer: Tracer)
  def run([token_contract_address], _json_rpc_named_arguments) do
    case Chain.token_from_address_hash(token_contract_address) do
      {:ok, %Token{} = token} ->
        catalog_token(token)
    end
  end

  @doc """
  Fetches token data asynchronously given a list of `t:Explorer.Chain.Token.t/0`s.
  """
  @spec async_fetch([Address.t()], boolean()) :: :ok
  def async_fetch(token_contract_addresses, realtime?) do
    BufferedTask.buffer(__MODULE__, token_contract_addresses, realtime?)
  end

  defp catalog_token(token) do
    token
    |> MetadataRetriever.get_functions_of(set_skip_metadata: true)
    |> apply_predeploy_overrides(token)
    |> case do
      :no_metadata ->
        :ok

      token_params ->
        data_for_multichain = MultichainSearch.prepare_token_metadata_for_queue(token, token_params)

        %{}
        |> Map.put(token.contract_address_hash.bytes, data_for_multichain)
        |> MultichainSearch.send_token_info_to_queue(:metadata)

        {:ok, _} = Token.update(token, Map.put(token_params, :cataloged, true))
        :ok
    end
  end

  # Overlay hardcoded metadata for known Mantle predeploys (e.g. WETH at
  # 0xdEAd...1111) when their on-chain `name()`/`symbol()`/`decimals()` calls
  # don't yield usable values. On-chain values still win — overrides only fill
  # nil or empty fields, so a real ERC-20 that happens to share an address
  # would not be silently relabeled.
  #
  # Note: the contract at 0xdEAd…1111 doesn't revert; it returns empty strings
  # for `name()` and `symbol()`. Treat `""` as missing too, otherwise the
  # overlay would never apply.
  defp apply_predeploy_overrides(params, token) do
    case Predeploys.lookup(token.contract_address_hash) do
      nil ->
        case params do
          %{skip_metadata: false} -> :no_metadata
          token_params -> token_params
        end

      overrides ->
        params
        |> Map.drop([:skip_metadata])
        |> Map.merge(overrides, fn _key, on_chain, hardcoded ->
          if blank?(on_chain), do: hardcoded, else: on_chain
        end)
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp defaults do
    [
      flush_interval: 300,
      max_batch_size: 1,
      max_concurrency: Application.get_env(:indexer, __MODULE__)[:concurrency] || @default_max_concurrency,
      task_supervisor: Indexer.Fetcher.Token.TaskSupervisor
    ]
  end
end
