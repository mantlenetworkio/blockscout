defmodule BlockScoutWeb.V2.SubblockChannel do
  @moduledoc """
  Live subblocks of the OP Stack subblocks (flashblocks) stream, relayed by `BlockScoutWeb.Subblocks.Relay` on the
  `subblocks:new` topic (event `new_subblock`).

  Joining replies with the buffered recent subblocks, so a client draws the block being built at once. Phoenix
  rejoins after a reconnect, which sends the client a fresh snapshot.
  """

  use BlockScoutWeb, :channel

  alias BlockScoutWeb.Subblocks.Buffer

  def join("subblocks:new", _params, socket), do: {:ok, %{items: Buffer.recent()}, socket}
  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown topic"}}
end
