defmodule BlockScoutWeb.Subblocks.Relay do
  @moduledoc """
  Subscribes to the subblocks stream of the flashblocks ws-proxy and rebroadcasts the summary of each subblock on the
  `subblocks:new` topic of this node's endpoint.

  Every frame carries one subblock with its index in the block (`Frame`). The explorer broadcasts locally only, so
  every API node runs its own relay and holds its own proxy connection. The URL carries the proxy key in its path: it
  is read in `start_link/1`, never logged, and kept neither in the child spec nor in the process state.
  """

  use WebSockex

  require Logger

  alias BlockScoutWeb.Endpoint
  alias BlockScoutWeb.Subblocks.{Buffer, Frame}

  @topic "subblocks:new"
  @event "new_subblock"
  # A frame holds one slice of about 200 ms; one this large is not decoded.
  @max_frame_bytes 1_048_576
  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000
  @idle_timeout_ms 30_000
  @dropped_log_interval_ms 60_000

  @doc "Connects to `SUBBLOCKS_WS_URL`, read here rather than passed in so that it stays out of the child spec."
  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(_arg) do
    url = Application.get_env(:block_scout_web, BlockScoutWeb.Subblocks)[:ws_url]
    options = [name: __MODULE__, async: true, handle_initial_conn_failure: true] ++ tls_options(url)
    WebSockex.start_link(url, __MODULE__, initial_state(), options)
  end

  @spec initial_state() :: map()
  def initial_state, do: %{backoff: @initial_backoff_ms, idle_timer: nil, dropped: 0, dropped_logged_at: nil}

  @doc "The wait before the next reconnect: doubles, capped at #{@max_backoff_ms} ms."
  @spec next_backoff(pos_integer()) :: pos_integer()
  def next_backoff(backoff_ms), do: min(backoff_ms * 2, @max_backoff_ms)

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("Subblocks relay connected")
    {:ok, arm_idle_timer(state)}
  end

  @impl WebSockex
  def handle_frame({type, frame}, state) when type in [:text, :binary] and byte_size(frame) > @max_frame_bytes do
    {:ok, state |> arm_idle_timer() |> count_dropped(:frame_too_large)}
  end

  def handle_frame({type, frame}, state) when type in [:text, :binary] do
    state = arm_idle_timer(state)

    case Frame.parse(frame, System.system_time(:millisecond)) do
      {:ok, item} ->
        if Buffer.put(item) in [:new, :replaced], do: Endpoint.local_broadcast(@topic, @event, item)
        {:ok, %{state | backoff: @initial_backoff_ms}}

      {:error, reason} ->
        {:ok, count_dropped(state, reason)}
    end
  end

  # Only the timer armed last counts: an earlier one may have fired before it was cancelled.
  @impl WebSockex
  def handle_info({:timeout, timer, :idle_timeout}, %{idle_timer: timer} = state) do
    Logger.warning("Subblocks relay got no frame for #{div(@idle_timeout_ms, 1_000)} s, reconnecting")
    # A quiet stream (a paused chain) is no failure of the proxy, so the reconnect after it waits the shortest time.
    {:close, %{state | idle_timer: nil, backoff: @initial_backoff_ms}}
  end

  def handle_info(_message, state), do: {:ok, state}

  # A dedicated process, so sleeping here only delays its own reconnect.
  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("Subblocks relay disconnected (#{describe(reason)}), reconnecting in #{state.backoff} ms")
    state = cancel_idle_timer(state)
    Process.sleep(state.backoff)
    {:reconnect, %{state | backoff: next_backoff(state.backoff)}}
  end

  # Categories and codes only: a close message or an error's text may quote the URL, and with it the key.
  defp describe({side, :closed}), do: "#{side} close"
  defp describe({side, :normal}), do: "#{side} close"
  defp describe({side, code, _message}) when is_integer(code), do: "#{side} close #{code}"
  defp describe(%WebSockex.RequestError{code: code}), do: "HTTP #{code}"
  defp describe(%WebSockex.ConnError{original: original}) when is_atom(original), do: "connection error #{original}"
  defp describe(%module{}), do: inspect(module)
  defp describe(_reason), do: "other"

  defp arm_idle_timer(state) do
    state = cancel_idle_timer(state)
    %{state | idle_timer: :erlang.start_timer(@idle_timeout_ms, self(), :idle_timeout)}
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  # Logs dropped frames at most once a minute, with the count since the last log line.
  defp count_dropped(state, reason) do
    now = System.monotonic_time(:millisecond)
    dropped = state.dropped + 1

    if is_nil(state.dropped_logged_at) or now - state.dropped_logged_at >= @dropped_log_interval_ms do
      Logger.warning("Subblocks relay dropped #{dropped} frame(s), the last one: #{reason}")
      %{state | dropped: 0, dropped_logged_at: now}
    else
      %{state | dropped: dropped}
    end
  end

  @doc false
  # Same verification as EthereumJSONRPC.WebSocket.WebSocketClient for every scheme WebSockex connects to over TLS.
  @spec tls_options(String.t()) :: Keyword.t()
  def tls_options(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["wss", "https"] and is_binary(host) ->
        verified_tls_options(String.to_charlist(host))

      _ ->
        []
    end
  end

  defp verified_tls_options(host) do
    [
      insecure: false,
      ssl_options: [
        cacerts: :certifi.cacerts(),
        depth: 99,
        server_name_indication: host,
        verify_fun: {&:ssl_verify_hostname.verify_fun/3, [check_hostname: host]},
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end
end
