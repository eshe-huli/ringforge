defmodule Hub.EventBus do
  @moduledoc """
  Pluggable event bus behaviour for Ringforge.

  Defines the contract that all event bus backends must implement.
  The active backend is selected via config:

      config :hub, event_bus: Hub.EventBus.Kafka

  Convenience functions delegate to the configured implementation,
  so callers simply use `Hub.EventBus.publish/2` etc. without
  knowing which backend is active.

  ## Backends

  - `Hub.EventBus.Kafka` — production backend (Apache Kafka via brod)
  - `Hub.EventBus.Local` — ETS-backed dev/test fallback
  """

  @type topic :: String.t()
  @type event :: map()

  @callback publish(topic(), event()) :: :ok | {:error, term()}
  @callback subscribe(topic(), opts :: keyword()) :: :ok | {:error, term()}
  @callback replay(topic(), opts :: keyword()) :: {:ok, [event()]} | {:error, term()}

  # ── Convenience delegators ───────────────────────────────────

  @doc "Publish an event to the configured backend."
  @spec publish(topic(), event()) :: :ok | {:error, term()}
  def publish(topic, event) do
    impl().publish(topic, event)
  end

  @doc "Subscribe to a topic on the configured backend."
  @spec subscribe(topic(), keyword()) :: :ok | {:error, term()}
  def subscribe(topic, opts \\ []) do
    impl().subscribe(topic, opts)
  end

  @doc "Replay events from a topic on the configured backend."
  @spec replay(topic(), keyword()) :: {:ok, [event()]} | {:error, term()}
  def replay(topic, opts \\ []) do
    impl().replay(topic, opts)
  end

  @doc "Returns the configured EventBus implementation module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:hub, :event_bus, Hub.EventBus.Local)
  end
end
