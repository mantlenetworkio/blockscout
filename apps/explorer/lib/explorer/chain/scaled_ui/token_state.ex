defmodule Explorer.Chain.ScaledUi.TokenState do
  @moduledoc """
  1:1 side table carrying all ERC-8056 per-token state.

  Kept off the hot `tokens` table (bridged_tokens precedent) so that summary
  rebuilds (`SELECT ... FOR UPDATE` on this table) never contend with the
  total-supply / counters / market updaters writing `tokens` rows, and so the
  overwhelmingly non-8056 token population carries no extra columns.

  The FK targets `addresses(hash)`, imported in the first serial stage, so
  capability/summary upserts never wait for the token catalog (same rationale
  as `scaled_ui_multiplier_updates`).

  Field groups, by write cadence:

    * multiplier summary: `base_multiplier` / `pending_multiplier` /
      `pending_effective_at`: rebuilt from the timeline on every relevant
      import;
    * capability & interface check: `capability_block`, `core_ext`,
      `scheduled_ext`, `iface_checked`: written once;
    * timeline integrity: `timeline_status`, `tainted_from_block`: rebuilt
      from canonical events and changed only when the timeline is re-evaluated.
  """

  use Explorer.Schema

  import Ecto.Query, only: [from: 2]

  alias Explorer.Chain.{Address, Hash, ScaledUiMultiplierUpdate}
  alias Explorer.Chain.ScaledUi.Timeline

  @timeline_statuses ~w(ok tainted)

  @optional_attrs ~w(base_multiplier pending_multiplier pending_effective_at capability_block
    core_ext scheduled_ext iface_checked timeline_status tainted_from_block)a

  @primary_key false
  typed_schema "scaled_ui_token_states" do
    field(:base_multiplier, :decimal)
    field(:pending_multiplier, :decimal)
    field(:pending_effective_at, :decimal)
    field(:capability_block, :integer)
    field(:core_ext, :boolean)
    field(:scheduled_ext, :boolean)
    field(:iface_checked, :boolean, default: false)
    field(:timeline_status, :string)
    field(:tainted_from_block, :integer)

    belongs_to(:token_contract_address, Address,
      foreign_key: :token_contract_address_hash,
      primary_key: true,
      references: :hash,
      type: Hash.Address,
      null: false
    )

    timestamps()
  end

  def changeset(%__MODULE__{} = state, params \\ %{}) do
    state
    |> cast(params, [:token_contract_address_hash | @optional_attrs])
    |> validate_required([:token_contract_address_hash])
    |> validate_inclusion(:timeline_status, @timeline_statuses)
    |> validate_pending_pair()
    |> validate_tainted_pair()
    |> validate_interface_results()
    |> foreign_key_constraint(:token_contract_address_hash)
  end

  @doc "Rebuilds capability boundaries and multiplier summaries for the supplied token addresses."
  @spec rebuild(module(), [map()]) :: {:ok, [Hash.Address.t()]}
  def rebuild(repo, capability_rows), do: rebuild(repo, capability_rows, [])

  @spec rebuild(module(), [map()], keyword()) :: {:ok, [Hash.Address.t()]}
  def rebuild(repo, capability_rows, options) when is_list(capability_rows) and is_list(options) do
    rows = normalize_capability_rows(capability_rows)
    now = DateTime.utc_now()
    timeout = Keyword.get(options, :timeout, 60_000)

    create_placeholders(repo, rows, now, timeout)

    states = lock_states(repo, Enum.map(rows, & &1.token_contract_address_hash), timeout)
    events_by_token = load_events(repo, Enum.map(rows, & &1.token_contract_address_hash), timeout)
    capability_blocks = Map.new(rows, &{&1.token_contract_address_hash, &1.capability_block})

    Enum.each(states, fn state ->
      summary = Timeline.replay(Map.get(events_by_token, state.token_contract_address_hash, []))

      state
      |> changeset(%{
        base_multiplier: summary.base_multiplier,
        pending_multiplier: summary.pending_multiplier,
        pending_effective_at: summary.pending_effective_at,
        capability_block: earliest_block(state.capability_block, capability_blocks[state.token_contract_address_hash]),
        timeline_status: summary.timeline_status,
        tainted_from_block: summary.tainted_from_block
      })
      |> repo.update!(timeout: timeout)
    end)

    {:ok, Enum.map(rows, & &1.token_contract_address_hash)}
  end

  defp normalize_capability_rows(capability_rows) do
    capability_rows
    |> Enum.reduce(%{}, fn row, acc ->
      hash = Map.fetch!(row, :token_contract_address_hash)
      block = Map.fetch!(row, :capability_block)
      Map.update(acc, hash, block, &min(&1, block))
    end)
    |> Enum.map(fn {hash, block} -> %{token_contract_address_hash: hash, capability_block: block} end)
    |> Enum.sort_by(&hash_sort_key(&1.token_contract_address_hash))
  end

  defp create_placeholders(repo, rows, now, timeout) do
    placeholders =
      Enum.map(rows, fn row ->
        %{
          token_contract_address_hash: row.token_contract_address_hash,
          iface_checked: false,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo.insert_all(__MODULE__, placeholders,
      conflict_target: :token_contract_address_hash,
      on_conflict: :nothing,
      timeout: timeout
    )
  end

  defp lock_states(repo, token_hashes, timeout) do
    query =
      from(state in __MODULE__,
        where: state.token_contract_address_hash in ^token_hashes,
        order_by: [asc: state.token_contract_address_hash],
        lock: "FOR UPDATE"
      )

    repo.all(query, timeout: timeout)
  end

  defp load_events(repo, token_hashes, timeout) do
    query =
      from(event in ScaledUiMultiplierUpdate,
        where: event.token_contract_address_hash in ^token_hashes,
        order_by: [
          asc: event.token_contract_address_hash,
          asc: event.block_number,
          asc: event.log_index
        ]
      )

    query
    |> repo.all(timeout: timeout)
    |> Enum.group_by(& &1.token_contract_address_hash)
  end

  defp earliest_block(nil, incoming), do: incoming
  defp earliest_block(existing, incoming), do: min(existing, incoming)

  defp hash_sort_key(%Hash{bytes: bytes}), do: bytes

  defp validate_pending_pair(changeset) do
    pending_multiplier = get_field(changeset, :pending_multiplier)
    pending_effective_at = get_field(changeset, :pending_effective_at)

    case {pending_multiplier, pending_effective_at} do
      {nil, nil} -> changeset
      {nil, _effective_at} -> add_error(changeset, :pending_multiplier, "must be present with pending effective time")
      {_multiplier, nil} -> add_error(changeset, :pending_effective_at, "must be present with pending multiplier")
      {_multiplier, _effective_at} -> changeset
    end
  end

  defp validate_tainted_pair(changeset) do
    timeline_tainted? = get_field(changeset, :timeline_status) == "tainted"
    tainted_block_present? = not is_nil(get_field(changeset, :tainted_from_block))

    if timeline_tainted? == tainted_block_present? do
      changeset
    else
      add_error(changeset, :tainted_from_block, "must be present exactly when timeline status is tainted")
    end
  end

  defp validate_interface_results(changeset) do
    iface_checked? = get_field(changeset, :iface_checked)
    core_ext = get_field(changeset, :core_ext)
    scheduled_ext = get_field(changeset, :scheduled_ext)

    case {iface_checked?, core_ext, scheduled_ext} do
      {false, nil, nil} ->
        changeset

      {true, core, scheduled} when is_boolean(core) and is_boolean(scheduled) ->
        changeset

      {false, _core, _scheduled} ->
        add_error(changeset, :iface_checked, "must be true when interface results are present")

      {true, nil, _scheduled} ->
        add_error(changeset, :core_ext, "must be present after interface check")

      {true, _core, nil} ->
        add_error(changeset, :scheduled_ext, "must be present after interface check")

      {_checked, _core, _scheduled} ->
        add_error(changeset, :iface_checked, "must be a boolean")
    end
  end
end
