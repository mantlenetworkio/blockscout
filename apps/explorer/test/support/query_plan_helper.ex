defmodule Explorer.QueryPlanHelper do
  @moduledoc """
  Checks in tests that a hot query can be served by the intended index.
  """

  alias Explorer.Repo

  @doc """
  Runs `fun`, takes the first query it sends that reads `table`, and returns that query's `EXPLAIN` output. The table
  is analyzed first and sequential scans are disabled, so the plan shows the index Postgres would pick on a real
  table. On a near-empty table every index costs the same, so give it some unrelated rows first.
  """
  @spec plan(String.t(), (-> any())) :: String.t()
  def plan(table, fun) do
    handler_id = {__MODULE__, make_ref()}
    test_process = self()
    quoted_table = ~s("#{table}")

    :ok =
      :telemetry.attach(
        handler_id,
        [:explorer, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_process and String.contains?(metadata.query, quoted_table) do
            send(test_process, {handler_id, metadata.query, metadata.params})
          end
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    receive do
      {^handler_id, query, params} ->
        Repo.query!("ANALYZE #{table}")
        Repo.query!("SET LOCAL enable_seqscan = off")
        %{rows: rows} = Repo.query!("EXPLAIN " <> query, params)
        Enum.map_join(rows, "\n", &hd/1)
    after
      0 -> raise "the function sent no query on #{table}"
    end
  end
end
