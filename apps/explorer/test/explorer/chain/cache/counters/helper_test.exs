defmodule Explorer.Chain.Cache.Counters.HelperTest do
  use Explorer.DataCase, async: false

  alias Explorer.Chain.Cache.Counters.Helper

  describe "with_statement_timeout/2" do
    test "returns the result of statements that finish in time" do
      assert {:ok, %{rows: [[1]]}} = Helper.with_statement_timeout(1_000, fn -> Repo.query!("SELECT 1") end)
    end

    test "cancels a statement that runs longer, and leaves no timeout behind on the connection" do
      assert {:error, :timeout} = Helper.with_statement_timeout(100, fn -> Repo.query!("SELECT pg_sleep(2)") end)

      assert %{rows: [["0"]]} = Repo.query!("SHOW statement_timeout")
    end

    test "leaves no timeout behind after statements that finish in time" do
      assert {:ok, _} = Helper.with_statement_timeout(100, fn -> Repo.query!("SELECT 1") end)

      assert %{rows: [["0"]]} = Repo.query!("SHOW statement_timeout")
    end

    test "refuses to run inside another transaction, which a cancelled statement would abort" do
      Repo.transaction(fn ->
        assert_raise ArgumentError, fn ->
          Helper.with_statement_timeout(100, fn -> Repo.query!("SELECT 1") end)
        end
      end)
    end

    test "raises any other database error" do
      assert_raise Postgrex.Error, fn ->
        Helper.with_statement_timeout(1_000, fn -> Repo.query!("SELECT 1 / 0") end)
      end
    end

    test "runs the statements without a timeout when given :infinity" do
      assert {:ok, %{rows: [[1]]}} = Helper.with_statement_timeout(:infinity, fn -> Repo.query!("SELECT 1") end)
    end
  end
end
