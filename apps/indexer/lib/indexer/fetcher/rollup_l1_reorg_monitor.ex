defmodule Indexer.Fetcher.RollupL1ReorgMonitor do
  @moduledoc """
  A module to monitor and catch L1 reorgs and make queue of the reorg blocks
  (if there are multiple reorgs) for rollup modules using this monitor.

  A rollup module uses the queue to detect a reorg and to do required actions.
  In case of reorg, the block number is popped from the queue by that rollup module.
  """

  use GenServer
  use Indexer.Fetcher
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  require Logger

  alias EthereumJSONRPC.Blocks
  alias Explorer.Chain.Cache.LatestL1BlockNumber
  alias Indexer.Helper
  alias Indexer.RollupReorgMonitorQueue

  @fetcher_name :rollup_l1_reorg_monitor
  @start_recheck_period_seconds 3

  defp modules_can_use_reorg_monitor do
    chain_type = Application.get_env(:explorer, :chain_type)

    case chain_type do
      :optimism ->
        [
          Indexer.Fetcher.Optimism.Deposit,
          Indexer.Fetcher.Optimism.OutputRoot,
          Indexer.Fetcher.Optimism.TransactionBatch,
          Indexer.Fetcher.Optimism.WithdrawalEvent
        ]

      :scroll ->
        [
          Indexer.Fetcher.Scroll.Batch,
          Indexer.Fetcher.Scroll.BridgeL1
        ]

      :shibarium ->
        [
          Indexer.Fetcher.Shibarium.L1
        ]

      _ ->
        []
    end
  end

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(_args) do
    {:ok, %{}, {:continue, :ok}}
  end

  @doc """
    This function initializes L1 blocks reorg monitor for the current rollup
    defined by CHAIN_TYPE. If the current chain is not a rollup, the module just
    doesn't start.

    The monitor is launched for certain modules of the rollup defined in
    `modules_can_use_reorg_monitor/0` function if a module starts (it can be
    switched off by configuration parameters). Whether each module starts or not
    is defined by the `requires_l1_reorg_monitor?` function of that module.

    The monitor starts an infinite loop of `eth_getBlockByNumber` requests
    sending them every `block_check_interval` milliseconds to retrieve the
    latest block number. To read the latest block number, RPC node of Layer 1 is
    used, which URL is defined by `l1_rpc_url` function of the rollup module.
    The `block_check_interval` is determined by the `get_block_check_interval`
    helper function. After the `block_check_interval` is defined, the function
    sends `:reorg_monitor` message to the GenServer to start the monitor loop.

    ## Returns
    - `{:ok, state}` with the determined parameters for the monitor loop if at
      least one rollup module is launched.
    - `{:stop, :normal, %{}}` if the monitor is not needed.
  """
  @impl GenServer
  def handle_continue(:ok, _state) do
    Logger.metadata(fetcher: @fetcher_name)

    # two seconds pause needed to avoid exceeding Supervisor restart intensity when RPC issues
    :timer.sleep(2000)

    modules_using_reorg_monitor =
      modules_can_use_reorg_monitor()
      |> Enum.filter(& &1.requires_l1_reorg_monitor?())

    if Enum.empty?(modules_using_reorg_monitor) do
      # don't start reorg monitor as there is no module which would use it
      {:stop, :normal, %{}}
    else
      l1_rpc = Enum.at(modules_using_reorg_monitor, 0).l1_rpc_url()

      json_rpc_named_arguments = Helper.json_rpc_named_arguments(l1_rpc)

      {:ok, block_check_interval, _} = Helper.get_block_check_interval(json_rpc_named_arguments)

      Process.send(self(), :reorg_monitor, [])

      {:noreply,
       %{
         block_check_interval: block_check_interval,
         json_rpc_named_arguments: json_rpc_named_arguments,
         modules: modules_using_reorg_monitor,
         prev_latest: 0,
         prev_latest_hash: nil
       }}
    end
  end

  @doc """
    Implements the monitor loop which requests RPC node for the latest block every
    `block_check_interval` milliseconds using `eth_getBlockByNumber` request.

    In case of reorg, the reorg block number is pushed into rollup module's queue.
    The block numbers are then popped by the rollup module from its queue and
    used to do some actions needed after reorg.

    ## Parameters
    - `:reorg_monitor`: The message triggering the next monitoring iteration.
    - `state`: The current state of the process, containing parameters for the
               monitoring (such as `block_check_interval`, `json_rpc_named_arguments`,
               the list of rollup modules in need of monitoring, the previous latest
               block number).

    ## Returns
    - `{:noreply, state}` where `state` contains the updated previous latest block number.
  """
  @impl GenServer
  def handle_info(
        :reorg_monitor,
        %{
          block_check_interval: block_check_interval,
          json_rpc_named_arguments: json_rpc_named_arguments,
          modules: modules,
          prev_latest: prev_latest,
          prev_latest_hash: prev_latest_hash
        } = state
      ) do
    new_state =
      case fetch_latest_block(json_rpc_named_arguments) do
        {:ok, latest_block} ->
          handle_latest_block(latest_block, modules, prev_latest, prev_latest_hash, json_rpc_named_arguments)
          %{state | prev_latest: latest_block.number, prev_latest_hash: latest_block.hash}

        {:error, reason} ->
          # Even with infinite_retries_number this branch can fire if the underlying call
          # returns a non-retryable {:error, _}. Keep the previous snapshot so the next tick
          # can re-verify the same prev_latest, and avoid crashing the monitor GenServer.
          Logger.error("Reorg monitor: cannot fetch latest L1 block — skipping this tick. Reason: #{inspect(reason)}")

          state
      end

    Process.send_after(self(), :reorg_monitor, block_check_interval)

    {:noreply, new_state}
  end

  @spec handle_latest_block(
          map(),
          [module()],
          non_neg_integer(),
          binary() | nil,
          EthereumJSONRPC.json_rpc_named_arguments()
        ) ::
          :ok
  defp handle_latest_block(latest_block, modules, prev_latest, prev_latest_hash, json_rpc_named_arguments) do
    latest = latest_block.number

    LatestL1BlockNumber.set_block_number(latest)

    previous_latest_block = %{number: prev_latest, hash: prev_latest_hash}
    current_previous_latest_block = fetch_current_previous_latest_block(prev_latest, latest, json_rpc_named_arguments)

    case reorg_block_to_enqueue(previous_latest_block, latest_block, current_previous_latest_block) do
      nil ->
        :ok

      reorg_block when latest < prev_latest ->
        Logger.warning("Reorg detected: previous latest block ##{prev_latest}, current latest block ##{latest}.")
        Enum.each(modules, &RollupReorgMonitorQueue.push(reorg_block, &1))

      reorg_block ->
        Logger.warning(
          "Reorg detected: L1 block ##{prev_latest} hash changed from #{prev_latest_hash} to #{current_previous_latest_block.hash}."
        )

        Enum.each(modules, &RollupReorgMonitorQueue.push(reorg_block, &1))
    end

    :ok
  end

  @doc false
  @spec reorg_block_to_enqueue(map(), map(), map() | nil) :: non_neg_integer() | nil
  def reorg_block_to_enqueue(%{number: prev_latest}, %{number: latest}, _current_previous_latest)
      when latest < prev_latest do
    latest
  end

  def reorg_block_to_enqueue(
        %{number: prev_latest, hash: prev_latest_hash},
        %{number: latest},
        %{hash: current_previous_latest_hash}
      )
      when latest >= prev_latest and is_binary(prev_latest_hash) and is_binary(current_previous_latest_hash) do
    if String.downcase(prev_latest_hash) != String.downcase(current_previous_latest_hash) do
      prev_latest
    end
  end

  def reorg_block_to_enqueue(_previous_latest, _latest, _current_previous_latest), do: nil

  defp fetch_latest_block(json_rpc_named_arguments) do
    error_message = &"Cannot fetch latest L1 block. Error: #{inspect(&1)}"

    Helper.repeated_call(
      &fetch_latest_block_once/1,
      [json_rpc_named_arguments],
      error_message,
      Helper.infinite_retries_number()
    )
  end

  defp fetch_latest_block_once(json_rpc_named_arguments) do
    case EthereumJSONRPC.fetch_block_by_tag("latest", json_rpc_named_arguments) do
      {:ok, %Blocks{blocks_params: [block], errors: []}} -> {:ok, block}
      {:ok, %Blocks{errors: [error | _]}} -> {:error, error}
      {:ok, _} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp fetch_current_previous_latest_block(0, _latest, _json_rpc_named_arguments), do: nil
  defp fetch_current_previous_latest_block(_prev_latest, latest, _json_rpc_named_arguments) when latest == 0, do: nil

  defp fetch_current_previous_latest_block(prev_latest, latest, _json_rpc_named_arguments) when latest < prev_latest,
    do: nil

  defp fetch_current_previous_latest_block(prev_latest, _latest, json_rpc_named_arguments) do
    error_message = &"Cannot fetch previous latest L1 block ##{prev_latest}. Error: #{inspect(&1)}"

    case Helper.repeated_call(
           &fetch_block_by_number/2,
           [prev_latest, json_rpc_named_arguments],
           error_message,
           Helper.infinite_retries_number()
         ) do
      {:ok, block} -> block
      {:error, _} -> nil
    end
  end

  defp fetch_block_by_number(block_number, json_rpc_named_arguments) do
    case EthereumJSONRPC.fetch_blocks_by_numbers([block_number], json_rpc_named_arguments, false) do
      {:ok, %Blocks{blocks_params: [block], errors: []}} -> {:ok, block}
      {:ok, %Blocks{errors: [error | _]}} -> {:error, error}
      {:ok, _} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
    Infinitely waits for the module to be initialized and started.

    ## Parameters
    - `waiting_module`: The module which called this function.

    ## Returns
    - nothing
  """
  @spec wait_for_start(module()) :: any()
  def wait_for_start(waiting_module) do
    state =
      try do
        __MODULE__
        |> Process.whereis()
        |> :sys.get_state()
      catch
        :exit, _ -> %{}
      end

    if map_size(state) == 0 do
      Logger.warning(
        "#{waiting_module} waits for #{__MODULE__} to start. Rechecking in #{@start_recheck_period_seconds} second(s)..."
      )

      :timer.sleep(@start_recheck_period_seconds * 1_000)
      wait_for_start(waiting_module)
    end
  end
end
