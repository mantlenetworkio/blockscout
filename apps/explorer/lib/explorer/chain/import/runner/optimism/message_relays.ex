defmodule Explorer.Chain.Import.Runner.Optimism.MessageRelays do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.Optimism.MessageRelay.t/0`.
  """

  require Ecto.Query

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.Import
  alias Explorer.Chain.Optimism.MessageRelay
  alias Explorer.Prometheus.Instrumenter

  import Ecto.Query, only: [from: 2]

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [MessageRelay.t()]

  @impl Import.Runner
  def ecto_schema_module, do: MessageRelay

  @impl Import.Runner
  def option_key, do: :optimism_message_relays

  @impl Import.Runner
  def imported_table_row do
    %{
      value_type: "[#{ecto_schema_module()}.t()]",
      value_description: "List of `t:#{ecto_schema_module()}.t/0`s"
    }
  end

  @impl Import.Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    Multi.run(multi, :insert_message_relays, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> insert(repo, changes_list, insert_options) end,
        :block_referencing,
        :optimism_message_relays,
        :optimism_message_relays
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map()], %{required(:timeout) => timeout(), required(:timestamps) => Import.timestamps()}) ::
          {:ok, [MessageRelay.t()]}
          | {:error, [Changeset.t()]}
  def insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options) when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    # Enforce MessageRelay ShareLocks order (see docs: sharelock.md)
    ordered_changes_list = Enum.sort_by(changes_list, &{&1.message_hash, &1.event_type, &1.transaction_hash})

    {:ok, inserted} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        for: MessageRelay,
        returning: true,
        timeout: timeout,
        timestamps: timestamps,
        conflict_target: [:message_hash, :event_type, :transaction_hash],
        on_conflict: on_conflict
      )

    {:ok, inserted}
  end

  defp default_on_conflict do
    from(
      relay in MessageRelay,
      update: [
        set: [
          # `message_hash`, `event_type` and `transaction_hash` form the primary key used as the conflict target
          chain: fragment("EXCLUDED.chain"),
          block_number: fragment("EXCLUDED.block_number"),
          inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", relay.inserted_at),
          updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", relay.updated_at)
        ]
      ],
      where:
        fragment(
          "(EXCLUDED.chain, EXCLUDED.block_number) IS DISTINCT FROM (?, ?)",
          relay.chain,
          relay.block_number
        )
    )
  end
end
