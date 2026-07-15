defmodule Explorer.Chain.ScaledUi.BackfillGap do
  @moduledoc """
  Persistent retry queue for block ranges that prevent complete ERC-8056 backfill.

  Claims use a short renewable lease so database work never runs while row locks
  are held. All ranges for one token share a stable lease ID, preventing concurrent
  full-token replays and stale workers from modifying reclaimed rows.
  """

  use Explorer.Schema

  import Ecto.Query

  alias Explorer.Chain.{Address, Hash}
  alias Explorer.Repo

  @lease_seconds 300
  @max_backoff_seconds 86_400

  @primary_key false
  typed_schema "scaled_ui_backfill_gaps" do
    field(:from_block, :integer, primary_key: true)
    field(:to_block, :integer)
    field(:retry_count, :integer, default: 0)
    field(:next_retry_at, :utc_datetime_usec)
    field(:lease_id, Ecto.UUID)
    field(:last_error, :string)

    belongs_to(:token_contract_address, Address,
      foreign_key: :token_contract_address_hash,
      primary_key: true,
      references: :hash,
      type: Hash.Address,
      null: false
    )

    timestamps()
  end

  def changeset(gap \\ %__MODULE__{}, params) do
    gap
    |> cast(params, [
      :token_contract_address_hash,
      :from_block,
      :to_block,
      :retry_count,
      :next_retry_at,
      :last_error
    ])
    |> validate_required([:token_contract_address_hash, :from_block, :to_block])
    |> validate_number(:from_block, greater_than_or_equal_to: 0)
    |> validate_number(:to_block, greater_than_or_equal_to: 0)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> validate_range()
    |> foreign_key_constraint(:token_contract_address_hash)
  end

  @doc "Upserts missing ranges for one token and makes new gaps immediately retryable."
  def put_ranges(repo, token_hash, ranges, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())

    rows =
      ranges
      |> Enum.map(fn %{from_block: from_block, to_block: to_block} ->
        %{
          token_contract_address_hash: token_hash,
          from_block: from_block,
          to_block: to_block,
          retry_count: 0,
          next_retry_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)
      |> Enum.uniq_by(& &1.from_block)

    repo.insert_all(__MODULE__, rows,
      conflict_target: [:token_contract_address_hash, :from_block],
      on_conflict:
        from(gap in __MODULE__,
          update: [
            set: [
              to_block: fragment("GREATEST(?, EXCLUDED.to_block)", gap.to_block),
              next_retry_at: fragment("EXCLUDED.next_retry_at"),
              lease_id: nil,
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      timeout: :infinity
    )
  end

  @doc "Claims one due token with SKIP LOCKED and returns its combined gap range."
  @spec claim_due(keyword()) :: [map()]
  def claim_due(options \\ []) do
    lease_seconds = Keyword.get(options, :lease_seconds, @lease_seconds)
    lease_id = Ecto.UUID.generate()
    {:ok, dumped_lease_id} = Ecto.UUID.dump(lease_id)

    Repo.transaction(
      fn ->
        Repo.query!(
          """
          WITH due_token AS (
            SELECT leader.token_contract_address_hash
            FROM scaled_ui_backfill_gaps AS leader
            WHERE leader.from_block = (
                    SELECT MIN(candidate.from_block)
                    FROM scaled_ui_backfill_gaps AS candidate
                    WHERE candidate.token_contract_address_hash = leader.token_contract_address_hash
                  )
              AND leader.next_retry_at <= NOW()
              AND NOT EXISTS (
                    SELECT 1
                    FROM scaled_ui_backfill_gaps AS blocked
                    WHERE blocked.token_contract_address_hash = leader.token_contract_address_hash
                      AND blocked.next_retry_at > NOW()
                  )
            ORDER BY leader.next_retry_at, leader.token_contract_address_hash
            FOR UPDATE OF leader SKIP LOCKED
            LIMIT 1
          ), claimed AS (
            UPDATE scaled_ui_backfill_gaps AS gap
            SET lease_id = $2::uuid,
                next_retry_at = NOW() + ($1 * INTERVAL '1 second'),
                updated_at = NOW()
            FROM due_token
            WHERE gap.token_contract_address_hash = due_token.token_contract_address_hash
            RETURNING gap.token_contract_address_hash, gap.from_block, gap.to_block,
                      gap.retry_count, gap.next_retry_at, gap.lease_id
          )
          SELECT token_contract_address_hash, MIN(from_block), MAX(to_block), MAX(retry_count),
                 MAX(next_retry_at), MIN(lease_id::text)
          FROM claimed
          GROUP BY token_contract_address_hash
          """,
          [lease_seconds, dumped_lease_id]
        ).rows
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, rows} -> Enum.map(rows, &row_to_claim/1)
      {:error, reason} -> raise reason
    end
  end

  @doc "Extends a token claim only while the caller still owns it."
  def renew_claim(claim, options \\ []) do
    lease_seconds = Keyword.get(options, :lease_seconds, @lease_seconds)

    from(gap in __MODULE__,
      where: gap.token_contract_address_hash == ^claim.token_contract_address_hash,
      where: gap.lease_id == ^claim.lease_id,
      update: [
        set: [
          next_retry_at: fragment("NOW() + (? * INTERVAL '1 second')", ^lease_seconds),
          updated_at: fragment("NOW()")
        ]
      ]
    )
    |> Repo.update_all([], timeout: :infinity)
  end

  @doc "Deletes all token gaps only if the caller still owns the claim."
  def complete_claim(claim) do
    from(gap in __MODULE__,
      where: gap.token_contract_address_hash == ^claim.token_contract_address_hash,
      where: gap.lease_id == ^claim.lease_id
    )
    |> Repo.delete_all(timeout: :infinity)
  end

  @doc "Releases a claimed gap with capped exponential backoff."
  def fail_claim(claim, error, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    backoff_seconds = min(round(:math.pow(2, claim.retry_count)) * 60, @max_backoff_seconds)

    from(gap in __MODULE__,
      where: gap.token_contract_address_hash == ^claim.token_contract_address_hash,
      where: gap.lease_id == ^claim.lease_id,
      update: [
        set: [
          retry_count: gap.retry_count + 1,
          next_retry_at: ^DateTime.add(now, backoff_seconds, :second),
          lease_id: nil,
          last_error: ^error_message(error),
          updated_at: ^now
        ]
      ]
    )
    |> Repo.update_all([], timeout: :infinity)
  end

  def count, do: Repo.aggregate(__MODULE__, :count, timeout: :infinity)

  defp row_to_claim([token_hash, from_block, to_block, retry_count, lease_until, lease_id]) do
    {:ok, token_hash} = Hash.Address.load(token_hash)

    %{
      token_contract_address_hash: token_hash,
      from_block: from_block,
      to_block: to_block,
      retry_count: retry_count,
      lease_until: normalize_timestamp(lease_until),
      lease_id: lease_id
    }
  end

  defp error_message(%{__exception__: true} = error), do: error |> Exception.message() |> String.slice(0, 255)
  defp error_message(error), do: error |> inspect() |> String.slice(0, 255)

  defp normalize_timestamp(%NaiveDateTime{} = timestamp), do: DateTime.from_naive!(timestamp, "Etc/UTC")
  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp

  defp validate_range(changeset) do
    from_block = get_field(changeset, :from_block)
    to_block = get_field(changeset, :to_block)

    if is_integer(from_block) and is_integer(to_block) and from_block > to_block do
      add_error(changeset, :to_block, "must be greater than or equal to from_block")
    else
      changeset
    end
  end
end
