defmodule Hub.FleetPresence do
  @moduledoc """
  Phoenix.Presence-backed presence tracker for fleet channels.

  Tracks per-agent metadata across the cluster using Phoenix PubSub.
  Each agent's presence includes: agent_id, name, framework, capabilities,
  state, task, load, connected_at.

  Unlike the DeltaCrdt-based `Hub.Presence` (used by KeyringChannel),
  this module integrates directly with Phoenix Channels and automatically
  handles join/leave diffing via PubSub.
  """
  use Phoenix.Presence,
    otp_app: :hub,
    pubsub_server: Hub.PubSub
end
