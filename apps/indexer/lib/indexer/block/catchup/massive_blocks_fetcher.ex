# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.Block.Catchup.MassiveBlocksFetcher do
  @moduledoc """
  Fetches and indexes blocks by numbers from massive_blocks table.
  """

  use GenServer

  require Logger

  alias Explorer.Utility.MassiveBlock
  alias Indexer.Block.Catchup.Fetcher, as: CatchupFetcher
  alias Indexer.Block.Fetcher

  @behaviour Fetcher

  @increased_interval 10000

  @type named_arguments :: %{required(:task_supervisor) => module()}

  @spec child_spec([named_arguments | GenServer.options(), ...]) :: Supervisor.child_spec()
  def child_spec([named_arguments]) when is_map(named_arguments), do: child_spec([named_arguments, []])

  def child_spec([named_arguments, gen_server_options] = start_link_arguments)
      when is_map(named_arguments) and is_list(gen_server_options) do
    Supervisor.child_spec(
      %{id: __MODULE__, start: {__MODULE__, :start_link, start_link_arguments}, type: :worker},
      []
    )
  end

  @spec start_link(named_arguments :: map()) :: GenServer.on_start()
  @spec start_link(named_arguments :: %{}, GenServer.options()) :: GenServer.on_start()
  def start_link(named_arguments, gen_server_options \\ [])
      when is_map(named_arguments) and is_list(gen_server_options) do
    GenServer.start_link(__MODULE__, named_arguments, gen_server_options)
  end

  @impl true
  def init(opts) do
    if !opts[:task_supervisor] do
      raise ArgumentError, ":task_supervisor must be provided to #{__MODULE__}.start_link/1"
    end

    send_new_task()

    {:ok, %{block_fetcher: generate_block_fetcher(opts), low_priority_blocks: []}}
  end

  @impl true
  def handle_info(:task, %{low_priority_blocks: low_priority_blocks} = state) do
    {result, new_low_priority_blocks} =
      case MassiveBlock.get_last_block_number(low_priority_blocks) do
        nil ->
          retry_low_priority_block(state.block_fetcher, low_priority_blocks)

        number ->
          failed_blocks = process_block(state.block_fetcher, number)
          {:processed, low_priority_blocks ++ failed_blocks}
      end

    case result do
      :processed -> send_new_task()
      _empty_or_failed_again -> send_new_task(@increased_interval)
    end

    {:noreply, %{state | low_priority_blocks: new_low_priority_blocks}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  # Only blocks that failed before are left: one that fails again waits for the
  # next round instead of being retried at once.
  defp retry_low_priority_block(_block_fetcher, []), do: {:empty, []}

  defp retry_low_priority_block(block_fetcher, [number | rest]) do
    case process_block(block_fetcher, number) do
      [] -> {:processed, rest}
      failed_blocks -> {:failed_again, rest ++ failed_blocks}
    end
  end

  @impl Fetcher
  def import(block_fetcher, options) do
    CatchupFetcher.import(block_fetcher, options)
  end

  defp process_block(block_fetcher, number) do
    case Fetcher.fetch_and_import_range(block_fetcher, number..number, %{timeout: :infinity}) do
      {:ok, %{errors: errors}} ->
        case Enum.reject(errors, &null_round?/1) do
          [] ->
            Logger.info("MassiveBlockFetcher successfully processed block #{inspect(number)}")
            MassiveBlock.delete_block_number(number)
            []

          # The node returned no block, so nothing was imported. The row stays for
          # a retry: once deleted, the block would be neither indexed nor
          # registered as missing until the missing ranges collector scans it again.
          fetch_errors ->
            Logger.error("MassiveBlockFetcher failed to fetch block #{inspect(number)}: #{inspect(fetch_errors)}")
            [number]
        end

      {:error, error} ->
        Logger.error("MassiveBlockFetcher failed: #{inspect(error)}")
        [number]
    end
  rescue
    error ->
      Logger.error("MassiveBlockFetcher failed: #{inspect(error)}")
      [number]
  end

  # a Filecoin null round has no block, as `Indexer.Block.Catchup.Fetcher` handles it
  defp null_round?(%{message: "requested epoch was a null round" <> _}), do: true
  defp null_round?(_error), do: false

  defp generate_block_fetcher(opts) do
    receipts_batch_size = Application.get_env(:indexer, :receipts_batch_size)
    receipts_concurrency = Application.get_env(:indexer, :receipts_concurrency)
    json_rpc_named_arguments = Application.get_env(:indexer, :json_rpc_named_arguments)

    %Fetcher{
      broadcast: :catchup,
      callback_module: __MODULE__,
      json_rpc_named_arguments: json_rpc_named_arguments,
      receipts_batch_size: receipts_batch_size,
      receipts_concurrency: receipts_concurrency,
      task_supervisor: opts[:task_supervisor]
    }
  end

  defp send_new_task(interval \\ 0) do
    Process.send_after(self(), :task, interval)
  end
end
