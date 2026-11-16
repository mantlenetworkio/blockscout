defmodule BlockScoutWeb.Subblocks.RelayTest do
  # The relay writes to the named buffer and broadcasts on the shared endpoint.
  use ExUnit.Case, async: false

  alias BlockScoutWeb.Subblocks.{Buffer, Relay}
  alias Phoenix.Socket.Broadcast

  @topic "subblocks:new"

  # One subblock as the ws-proxy sends it (mantle-reth `MantleFlashblockPayload`): only index 0 carries `base`.
  # `padding` bytes of metadata make a large frame.
  defp frame(block_number, index, transactions_count, padding \\ 0) do
    payload = %{
      "payload_id" => "0x0102030405060708",
      "index" => index,
      "diff" => %{"transactions" => List.duplicate("0x02f8b1", transactions_count), "gas_used" => "0x5208"},
      "metadata" => %{
        "block_number" => block_number,
        "prev_flashblock_id" => "#{block_number}-#{max(index - 1, 0)}",
        "receipts" => %{},
        "padding" => String.duplicate("0", padding)
      }
    }

    payload =
      if index == 0,
        do: Map.put(payload, "base", %{"block_number" => "0x" <> Integer.to_string(block_number, 16)}),
        else: payload

    Jason.encode!(payload)
  end

  setup do
    start_supervised!(Buffer)
    BlockScoutWeb.Endpoint.subscribe(@topic)
    on_exit(fn -> Phoenix.PubSub.unsubscribe(BlockScoutWeb.PubSub, @topic) end)
    :ok
  end

  test "backoff sequence" do
    assert 1000 |> Stream.iterate(&Relay.next_backoff/1) |> Enum.take(7) ==
             [1000, 2000, 4000, 8000, 16_000, 30_000, 30_000]
  end

  test "a frame is broadcast" do
    assert {:ok, _state} = Relay.handle_frame({:binary, frame(93_000_000, 1, 1)}, Relay.initial_state())

    assert_receive %Broadcast{
      topic: @topic,
      event: "new_subblock",
      payload: %{block_number: 93_000_000, index: 1, transactions_count: 1, gas_used: "21000"}
    }
  end

  test "a brotli-compressed frame" do
    compressed = ExBrotli.compress!(frame(93_000_000, 2, 0))

    assert {:ok, _state} = Relay.handle_frame({:binary, compressed}, Relay.initial_state())
    assert_receive %Broadcast{topic: @topic, payload: %{block_number: 93_000_000, index: 2}}
  end

  test "an unchanged repeat is not broadcast again" do
    {:ok, state} = Relay.handle_frame({:binary, frame(93_000_000, 1, 1)}, Relay.initial_state())
    assert_receive %Broadcast{topic: @topic}

    {:ok, _state} = Relay.handle_frame({:binary, frame(93_000_000, 1, 1)}, state)
    refute_receive %Broadcast{topic: @topic}
  end

  test "a bad frame is dropped" do
    assert {:ok, _state} = Relay.handle_frame({:binary, "[]"}, Relay.initial_state())
    refute_receive %Broadcast{topic: @topic}
  end

  test "an oversized frame is dropped without parsing" do
    assert {:ok, _state} = Relay.handle_frame({:binary, frame(93_000_000, 1, 1, 1_048_576)}, Relay.initial_state())
    refute_receive %Broadcast{topic: @topic}
  end

  test "a frame resets the backoff" do
    assert {:ok, %{backoff: 1000}} =
             Relay.handle_frame({:binary, frame(93_000_000, 1, 0)}, %{Relay.initial_state() | backoff: 8000})
  end

  test "a quiet stream does not stretch the next reconnect" do
    {:ok, state} = Relay.handle_connect(%WebSockex.Conn{}, %{Relay.initial_state() | backoff: 8000})

    assert {:close, %{backoff: 1000, idle_timer: nil}} =
             Relay.handle_info({:timeout, state.idle_timer, :idle_timeout}, state)
  end

  test "an idle timeout armed before the last frame is ignored" do
    {:ok, state} = Relay.handle_connect(%WebSockex.Conn{}, Relay.initial_state())
    stale = {:timeout, state.idle_timer, :idle_timeout}

    {:ok, state} = Relay.handle_frame({:binary, frame(93_000_000, 1, 0)}, state)

    assert {:ok, ^state} = Relay.handle_info(stale, state)
  end

  test "a disconnect waits for the backoff, then reconnects with a longer one" do
    {:ok, state} = Relay.handle_connect(%WebSockex.Conn{}, %{Relay.initial_state() | backoff: 50})
    started = System.monotonic_time(:millisecond)

    assert {:reconnect, %{backoff: 100, idle_timer: nil}} =
             Relay.handle_disconnect(%{reason: {:remote, :closed}, attempt_number: 1, conn: nil}, state)

    assert System.monotonic_time(:millisecond) - started >= 50
  end

  # The key is in the URL path, and a server may quote the path it refused.
  test "a disconnect is logged without the server's text" do
    state = %{Relay.initial_state() | backoff: 1}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Relay.handle_disconnect(
          %{reason: {:remote, 1008, "bad key /ws/secret-key"}, attempt_number: 1, conn: nil},
          state
        )

        Relay.handle_disconnect(%{reason: %WebSockex.RequestError{code: 401, message: "/ws/secret-key"}}, state)
      end)

    assert log =~ "1008"
    assert log =~ "401"
    refute log =~ "secret-key"
  end

  test "TLS settings follow the parsed scheme" do
    assert Relay.tls_options("WSS://proxy:443/ws/key")[:insecure] == false
    assert Relay.tls_options("https://proxy/ws/key")[:insecure] == false
    assert Relay.tls_options("ws://proxy:8545/ws/key") == []
  end
end
