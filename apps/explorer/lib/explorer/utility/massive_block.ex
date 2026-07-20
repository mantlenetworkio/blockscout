defmodule Explorer.Utility.MassiveBlock do
  @moduledoc """
  Module is responsible for keeping the block numbers that are too large for regular import
  and need more time to complete.
  """

  use Explorer.Schema

  alias Explorer.Repo

  @primary_key false
  typed_schema "massive_blocks" do
    field(:number, :integer, primary_key: true)

    timestamps()
  end

  @doc false
  def changeset(massive_block \\ %__MODULE__{}, params) do
    cast(massive_block, params, [:number])
  end

  def get_last_block_number(except_numbers) do
    __MODULE__
    |> where([mb], mb.number not in ^except_numbers)
    |> select([mb], max(mb.number))
    |> Repo.one()
  end

  def insert_block_numbers(numbers) do
    now = DateTime.utc_now()
    params = Enum.map(numbers, &%{number: &1, inserted_at: now, updated_at: now})

    Repo.insert_all(__MODULE__, params, on_conflict: {:replace, [:updated_at]}, conflict_target: :number)
  end

  def delete_block_number(number) do
    __MODULE__
    |> where([mb], mb.number == ^number)
    |> Repo.delete_all()
  end

  @doc "Returns deferred massive blocks that fall within an ascending range."
  @spec intersections(non_neg_integer(), non_neg_integer()) :: [
          %{from_block: non_neg_integer(), to_block: non_neg_integer()}
        ]
  def intersections(from_block, to_block)
      when is_integer(from_block) and is_integer(to_block) and from_block <= to_block do
    __MODULE__
    |> where([block], block.number >= ^from_block and block.number <= ^to_block)
    |> order_by([block], asc: block.number)
    |> select([block], block.number)
    |> Repo.all()
    |> Enum.map(&%{from_block: &1, to_block: &1})
  end

  @doc "Returns whether a deferred massive block falls within an ascending range."
  @spec exists_in_range?(non_neg_integer(), non_neg_integer()) :: boolean()
  def exists_in_range?(from_block, to_block)
      when is_integer(from_block) and is_integer(to_block) and from_block <= to_block do
    __MODULE__
    |> where([block], block.number >= ^from_block and block.number <= ^to_block)
    |> Repo.exists?()
  end
end
