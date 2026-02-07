defmodule Hub.MQTT.Bridge do
  @moduledoc """
  Lightweight MQTT bridge that connects an MQTT broker to the RingForge fleet.

  - Subscribes to configurable topic patterns (e.g., `home/#`, `sensors/#`)
  - Translates incoming MQTT messages → RingForge activity events
  - Translates RingForge commands → MQTT publishes

  Uses `tortoise311` for the MQTT client connection.

  ## Configuration

      config :hub, Hub.MQTT.Bridge,
        enabled: true,
        broker: "mqtt://localhost:1883",
        client_id: "ringforge-hub",
        topics: ["home/#", "sensors/#"],
        username: nil,
        password: nil

  Disabled by default. Set `MQTT_ENABLED=true` to activate.
  """

  use GenServer
  require Logger

  @reconnect_interval 10_000

  # ── Public API ─────────────────────────────────────────────

  @doc "Publish a message to an MQTT topic via the bridge."
  def publish(topic, payload) when is_binary(topic) do
    if enabled?() do
      GenServer.call(__MODULE__, {:publish, topic, payload}, 10_000)
    else
      {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :not_connected}
  end

  @doc "Check if the MQTT bridge is enabled and running."
  def enabled? do
    config()[:enabled] == true
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    config = config()

    if config[:enabled] do
      Logger.info("[MQTT.Bridge] Starting MQTT bridge → #{config[:broker]}")
      send(self(), :connect)

      {:ok,
       %{
         connected: false,
         client_id: config[:client_id] || "ringforge-hub",
         broker: config[:broker] || "mqtt://localhost:1883",
         topics: config[:topics] || ["home/#", "sensors/#"],
         username: config[:username],
         password: config[:password]
       }}
    else
      Logger.info("[MQTT.Bridge] MQTT bridge disabled (set MQTT_ENABLED=true to activate)")
      {:ok, %{connected: false, client_id: nil}}
    end
  end

  @impl GenServer
  def handle_info(:connect, %{client_id: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:connect, state) do
    case start_mqtt_client(state) do
      :ok ->
        Logger.info("[MQTT.Bridge] Connected to MQTT broker")
        {:noreply, %{state | connected: true}}

      {:error, reason} ->
        Logger.warning("[MQTT.Bridge] Connection failed: #{inspect(reason)}, retrying in #{@reconnect_interval}ms")
        Process.send_after(self(), :connect, @reconnect_interval)
        {:noreply, state}
    end
  end

  def handle_info({:mqtt, topic, payload}, state) do
    # Incoming MQTT message — translate to RingForge activity
    handle_mqtt_message(topic, payload)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[MQTT.Bridge] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:publish, _topic, _payload}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, topic, payload}, _from, state) do
    encoded =
      cond do
        is_binary(payload) -> payload
        is_map(payload) -> Jason.encode!(payload)
        true -> inspect(payload)
      end

    case do_publish(state.client_id, topic, encoded) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("[MQTT.Bridge] Publish failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # ── MQTT Client (Tortoise311-based) ────────────────────────

  defp start_mqtt_client(state) do
    {host, port} = parse_broker_url(state.broker)

    server_opts =
      if port == 8883 do
        {Tortoise.Transport.SSL, host: host, port: port}
      else
        {Tortoise.Transport.Tcp, host: host, port: port}
      end

    subscriptions =
      Enum.map(state.topics, fn topic ->
        {topic, 0}
      end)

    opts = [
      client_id: state.client_id,
      handler: {Hub.MQTT.Handler, [bridge_pid: self()]},
      server: server_opts,
      subscriptions: subscriptions
    ]

    # Add auth if configured
    opts =
      if state.username do
        Keyword.put(opts, :user_name, state.username)
        |> Keyword.put(:password, state.password)
      else
        opts
      end

    case Tortoise.Connection.start_link(opts) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[MQTT.Bridge] Client start error: #{Exception.message(e)}")
      {:error, :client_start_failed}
  end

  defp do_publish(client_id, topic, payload) do
    case Tortoise.publish(client_id, topic, payload, qos: 0) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :publish_failed}
  end

  defp parse_broker_url(url) do
    uri = URI.parse(url)
    host = uri.host || "localhost"

    port =
      cond do
        uri.port -> uri.port
        uri.scheme == "mqtts" -> 8883
        true -> 1883
      end

    {String.to_charlist(host), port}
  end

  # ── Message Translation ────────────────────────────────────

  defp handle_mqtt_message(topic, payload) do
    Logger.debug("[MQTT.Bridge] Received: #{topic} → #{inspect(payload)}")

    value = parse_mqtt_payload(payload)

    # Try to match to a registered device by topic
    # Broadcast on all fleets that have devices with matching topics
    Task.start(fn ->
      import Ecto.Query

      devices =
        Hub.Schemas.Device
        |> where(topic: ^topic, protocol: "mqtt")
        |> Hub.Repo.all()

      if devices == [] do
        # No device match — broadcast as generic MQTT event
        Logger.debug("[MQTT.Bridge] No device matched topic #{topic}")
      else
        Enum.each(devices, fn device ->
          Hub.Devices.update_reading(device.id, value, device.fleet_id)
        end)
      end
    end)
  end

  defp parse_mqtt_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"value" => decoded}
      _ ->
        case Float.parse(payload) do
          {num, _} -> %{"value" => num}
          :error -> %{"raw" => payload}
        end
    end
  end

  defp parse_mqtt_payload(payload), do: %{"raw" => inspect(payload)}

  defp config do
    Application.get_env(:hub, __MODULE__, [])
  end
end
