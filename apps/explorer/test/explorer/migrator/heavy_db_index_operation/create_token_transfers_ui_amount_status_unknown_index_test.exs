defmodule Explorer.Migrator.HeavyDbIndexOperation.CreateTokenTransfersUiAmountStatusUnknownIndexTest do
  use Explorer.DataCase, async: false

  alias Explorer.Chain.Cache.BackgroundMigrations
  alias Explorer.Migrator.{HeavyDbIndexOperation, MigrationStatus}
  alias Explorer.Migrator.HeavyDbIndexOperation.CreateTokenTransfersUiAmountStatusUnknownIndex
  alias Explorer.Migrator.HeavyDbIndexOperation.Helper
  alias Explorer.Repo

  @index_name "token_transfers_ui_amount_status_unknown_index"

  describe "ERC-8056 unknown status partial index" do
    setup do
      configuration = Application.get_env(:explorer, HeavyDbIndexOperation)
      Application.put_env(:explorer, HeavyDbIndexOperation, check_interval: 50)
      assert :ok = Helper.safely_drop_db_index(@index_name)

      on_exit(fn ->
        Application.put_env(:explorer, HeavyDbIndexOperation, configuration)
      end)

      :ok
    end

    test "creates and tracks the partial index" do
      migration_name = "heavy_indexes_create_token_transfers_ui_amount_status_unknown_index"

      assert MigrationStatus.get_status(migration_name) == nil
      assert Helper.db_index_exists_and_valid?(@index_name) == %{exists?: false, valid?: nil}

      start_supervised!(CreateTokenTransfersUiAmountStatusUnknownIndex)

      assert eventually(fn -> MigrationStatus.get_status(migration_name) == "completed" end)
      assert Helper.db_index_exists_and_valid?(@index_name) == %{exists?: true, valid?: true}

      assert {:ok, %{rows: [[index_definition]]}} =
               Repo.query("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [@index_name])

      assert index_definition =~ "(token_contract_address_hash, block_number)"
      assert index_definition =~ "WHERE"
      assert index_definition =~ "ui_amount_status"
      assert index_definition =~ "unknown"

      assert BackgroundMigrations.get_heavy_indexes_create_token_transfers_ui_amount_status_unknown_index_finished() ==
               true
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
