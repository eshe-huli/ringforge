defmodule Hub.Events do
  @moduledoc """
  EventBus — structured internal event broadcasting via Phoenix.PubSub.

  Every significant operation emits a structured event containing:

      %{
        type:        atom,
        source_node: binary,
        timestamp:   integer,
        payload:     map
      }

  ## Usage

      Hub.Events.emit(:node_joined, %{node_id: "abc123"})
      Hub.Events.subscribe(:node_joined)
      Hub.Events.subscribe()  # all events

  Subscribers receive `{:hub_event, event_map}` messages.
  """

  @pubsub Hub.PubSub
  @all_events_topic "hub:events"

  @type event :: %{
          type: atom(),
          source_node: node(),
          timestamp: integer(),
          payload: map()
        }

  @doc """
  Emit a structured event. Publishes to both the typed topic and the
  catch-all `hub:events` topic. Also fires a telemetry event.
  """
  @spec emit(atom(), map()) :: :ok
  def emit(type, payload \\ %{}) when is_atom(type) and is_map(payload) do
    event = %{
      type: type,
      source_node: node(),
      timestamp: System.system_time(:microsecond),
      payload: payload
    }

    # Broadcast on typed topic
    Phoenix.PubSub.broadcast(@pubsub, topic(type), {:hub_event, event})
    # Broadcast on catch-all topic
    Phoenix.PubSub.broadcast(@pubsub, @all_events_topic, {:hub_event, event})

    # Also fire telemetry
    telemetry_event = [:hub, :event, type]
    :telemetry.execute(telemetry_event, %{system_time: event.timestamp}, %{
      type: type,
      payload: payload
    })

    :ok
  end

  @doc "Subscribe to a specific event type."
  @spec subscribe(atom()) :: :ok | {:error, term()}
  def subscribe(type) when is_atom(type) do
    Phoenix.PubSub.subscribe(@pubsub, topic(type))
  end

  @doc "Subscribe to all events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @all_events_topic)
  end

  @doc "Unsubscribe from a specific event type."
  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(type) when is_atom(type) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(type))
  end

  @doc "Unsubscribe from all events."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(@pubsub, @all_events_topic)
  end

  defp topic(type), do: "hub:events:#{type}"
end
