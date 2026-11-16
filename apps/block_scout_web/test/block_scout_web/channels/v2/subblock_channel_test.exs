defmodule BlockScoutWeb.V2.SubblockChannelTest do
  # The buffer is a named process and the subblocks_children/0 tests change application env.
  use BlockScoutWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias BlockScoutWeb.Subblocks.{Buffer, Relay}
  alias BlockScoutWeb.Subblocks.Supervisor, as: SubblocksSupervisor
  alias BlockScoutWeb.V2.UserSocket

  defp item(index) do
    %{
      block_number: 100,
      index: index,
      transactions_count: 0,
      gas_used: "46299",
      received_at: System.system_time(:millisecond)
    }
  end

  defp join(topic), do: UserSocket |> socket("no_id", %{}) |> subscribe_and_join(topic)

  describe "join" do
    setup do
      start_supervised!(Buffer)
      :ok
    end

    test "join with an empty buffer" do
      assert {:ok, %{items: []}, _socket} = join("subblocks:new")
    end

    test "join returns the buffer" do
      for index <- 0..2, do: Buffer.put(item(index))

      assert {:ok, %{items: items}, _socket} = join("subblocks:new")
      assert items == Buffer.recent()
      assert length(items) == 3
    end

    test "unknown subtopic" do
      assert {:error, %{reason: "unknown topic"}} = join("subblocks:other")
    end
  end

  describe "subblocks_children/0" do
    setup do
      subblocks_env = Application.get_env(:block_scout_web, BlockScoutWeb.Subblocks)
      mode = Application.get_env(:explorer, :mode)

      on_exit(fn ->
        Application.put_env(:block_scout_web, BlockScoutWeb.Subblocks, subblocks_env)
        Application.put_env(:explorer, :mode, mode)
      end)
    end

    test "no relay without a URL" do
      Application.put_env(:block_scout_web, BlockScoutWeb.Subblocks, ws_url: "")
      Application.put_env(:explorer, :mode, :all)

      assert BlockScoutWeb.Application.subblocks_children() == []
    end

    test "buffer and relay with a URL" do
      Application.put_env(:block_scout_web, BlockScoutWeb.Subblocks, ws_url: "ws://proxy:8545/ws/secret-key")
      Application.put_env(:explorer, :mode, :all)

      assert BlockScoutWeb.Application.subblocks_children() == [SubblocksSupervisor]
    end

    # A relay that keeps crashing ends with its own supervisor, which then stays down instead of escalating to the API's.
    test "the subblocks supervisor is not restarted once it gives up" do
      assert %{restart: :temporary} = Supervisor.child_spec(SubblocksSupervisor, [])

      assert {:ok, {%{intensity: 5, period: 60}, [%{id: Buffer}, %{id: Relay}]}} =
               SubblocksSupervisor.init(nil)
    end

    # A supervisor report of a crashed child prints its start call.
    test "the child specs carry no URL" do
      Application.put_env(:block_scout_web, BlockScoutWeb.Subblocks, ws_url: "ws://proxy:8545/ws/secret-key")
      Application.put_env(:explorer, :mode, :all)

      specs = Enum.map(BlockScoutWeb.Application.subblocks_children(), &Supervisor.child_spec(&1, []))
      refute inspect(specs) =~ "secret-key"
    end

    # A child that fails to start would stop the whole application.
    test "no relay with a malformed URL" do
      Application.put_env(:block_scout_web, BlockScoutWeb.Subblocks, ws_url: "proxy:8545/ws/secret-key")
      Application.put_env(:explorer, :mode, :all)

      log = capture_log(fn -> assert BlockScoutWeb.Application.subblocks_children() == [] end)
      assert log =~ "SUBBLOCKS_WS_URL"
      refute log =~ "secret-key"
    end

    test "no relay with a port out of range" do
      Application.put_env(:block_scout_web, BlockScoutWeb.Subblocks, ws_url: "ws://proxy:70000/ws/secret-key")
      Application.put_env(:explorer, :mode, :all)

      log = capture_log(fn -> assert BlockScoutWeb.Application.subblocks_children() == [] end)
      assert log =~ "SUBBLOCKS_WS_URL"
      refute log =~ "secret-key"
    end

    test "no relay in indexer mode" do
      Application.put_env(:block_scout_web, BlockScoutWeb.Subblocks, ws_url: "ws://proxy:8545/ws/secret-key")
      Application.put_env(:explorer, :mode, :indexer)

      assert BlockScoutWeb.Application.subblocks_children() == []
    end
  end
end
