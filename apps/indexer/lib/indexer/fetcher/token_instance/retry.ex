# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.Fetcher.TokenInstance.Retry do
  @moduledoc """
  Fetches information about a token instance.
  """

  use Indexer.Fetcher, restart: :permanent
  use Spandex.Decorators

  import Indexer.Fetcher.TokenInstance.Helper

  alias Explorer.Chain.Token.Instance
  alias Indexer.BufferedTask

  @behaviour BufferedTask

  @default_max_batch_size 10
  @default_max_concurrency 10

  @doc false
  def child_spec([init_options, gen_server_options]) do
    merged_init_opts =
      defaults()
      |> Keyword.merge(init_options)
      |> Keyword.merge(state: [])

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial_acc, reducer, _) do
    # Read one bounded batch with a plain query. Streaming every failed instance waited for queue
    # space inside the stream's transaction, which stayed idle for hours on a large backlog and held
    # back vacuum for the whole database. The BufferedTask polls again only once the queue has
    # drained, so the queue holds at most one batch and needs no back-pressure here.
    # The limit (INDEXER_TOKEN_INSTANCE_RETRY_INIT_QUERY_LIMIT) should exceed batch size × concurrency:
    # if the workers take the whole batch at once, init ends with an empty queue and the next poll
    # waits INDEXER_FETCHER_INIT_DELAY.
    Application.get_env(:indexer, __MODULE__)[:init_limit]
    |> Instance.token_instances_to_retry()
    |> Enum.reduce(initial_acc, reducer)
  end

  @impl BufferedTask
  def run(token_instances, _json_rpc_named_arguments) when is_list(token_instances) do
    batch_fetch_instances(token_instances)

    :ok
  end

  defp defaults do
    [
      flush_interval: :timer.seconds(10),
      max_concurrency: Application.get_env(:indexer, __MODULE__)[:concurrency] || @default_max_concurrency,
      max_batch_size: Application.get_env(:indexer, __MODULE__)[:batch_size] || @default_max_batch_size,
      task_supervisor: __MODULE__.TaskSupervisor
    ]
  end
end
