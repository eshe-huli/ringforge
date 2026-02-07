defmodule Hub.MQTT.Handler do
  @moduledoc """
  Tortoise311 MQTT handler that forwards messages to the MQTT Bridge.

  Implements the `Tortoise.Handler` behaviour (or a simplified version
  if tortoise311 isn't available). Messages are forwarded to the bridge
  GenServer for processing.
  """

  require Logger

  @behaviour Tortoise.Handler

  @impl Tortoise.Handler
  def init(opts) do
    bridge_pid = Keyword.get(opts, :bridge_pid)
    {:ok, %{bridge_pid: bridge_pid}}
  end

  @impl Tortoise.Handler
  def connection(:up, state) do
    Logger.info("[MQTT.Handler] Connection established")
    {:ok, state}
  end

  def connection(:down, state) do
    Logger.warning("[MQTT.Handler] Connection lost")
    {:ok, state}
  end

  def connection(:terminating, state) do
    Logger.info("[MQTT.Handler] Connection terminating")
    {:ok, state}
  end

  @impl Tortoise.Handler
  def subscription(:up, topic, _qos, state) do
    Logger.info("[MQTT.Handler] Subscribed to #{topic}")
    {:ok, state}
  end

  def subscription(:down, topic, state) do
    Logger.info("[MQTT.Handler] Unsubscribed from #{topic}")
    {:ok, state}
  end

  def subscription({:warn, warnings}, _topic, state) do
    Logger.warning("[MQTT.Handler] Subscription warnings: #{inspect(warnings)}")
    {:ok, state}
  end

  def subscription({:error, reasons}, _topic, state) do
    Logger.error("[MQTT.Handler] Subscription error: #{inspect(reasons)}")
    {:ok, state}
  end

  @impl Tortoise.Handler
  def handle_message(topic_parts, payload, state) do
    topic = Enum.join(topic_parts, "/")

    if state.bridge_pid && Process.alive?(state.bridge_pid) do
      send(state.bridge_pid, {:mqtt, topic, payload})
    end

    {:ok, state}
  end

  @impl Tortoise.Handler
  def terminate(_reason, _state) do
    :ok
  end
end
