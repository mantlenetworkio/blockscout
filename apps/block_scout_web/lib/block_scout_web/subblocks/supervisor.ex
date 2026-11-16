defmodule BlockScoutWeb.Subblocks.Supervisor do
  @moduledoc """
  Runs the subblocks buffer and relay apart from the rest of the API.

  A relay that keeps crashing (an upstream answering the handshake in a way WebSockex does not handle) exhausts this
  supervisor's restarts. It then stops for good, taking only the homepage card and the Subblocks tab with it, instead
  of escalating to the API's supervisor.
  """

  use Supervisor, restart: :temporary

  alias BlockScoutWeb.Subblocks.{Buffer, Relay}

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg), do: Supervisor.init([Buffer, Relay], strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
end
