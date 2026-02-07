defmodule Hub.Metrics do
  @moduledoc """
  Telemetry handler that maintains ETS-backed Prometheus-style metrics.

  Attaches to Hub telemetry events and tracks counters, gauges, and histograms
  in an ETS table. The MetricsController reads from this table to serve
  the /metrics endpoint.

  No external Prometheus library required — metrics are stored as simple
  ETS entries and formatted as Prometheus text exposition format on demand.
  """
  use GenServer

  require Logger

  @table :hub_metrics
  @histogram_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0]

  # ── Public API ─────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment a counter metric."
  def inc(name, labels \\ %{}, amount \\ 1) do
    key = {:counter, name, normalize_labels(labels)}
    try do
      :ets.update_counter(@table, key, {2, amount})
    catch
      :error, :badarg ->
        :ets.insert_new(@table, {key, amount})
    end
  end

  @doc "Set a gauge metric."
  def gauge_set(name, labels \\ %{}, value) do
    key = {:gauge, name, normalize_labels(labels)}
    :ets.insert(@table, {key, value})
  end

  @doc "Increment a gauge metric."
  def gauge_inc(name, labels \\ %{}, amount \\ 1) do
    key = {:gauge, name, normalize_labels(labels)}
    try do
      :ets.update_counter(@table, key, {2, amount})
    catch
      :error, :badarg ->
        :ets.insert_new(@table, {key, amount})
    end
  end

  @doc "Decrement a gauge metric."
  def gauge_dec(name, labels \\ %{}, amount \\ 1) do
    key = {:gauge, name, normalize_labels(labels)}
    try do
      :ets.update_counter(@table, key, {2, -amount})
    catch
      :error, :badarg ->
        :ets.insert_new(@table, {key, -amount})
    end
  end

  @doc "Observe a value in a histogram metric."
  def histogram_observe(name, labels \\ %{}, value) do
    labels = normalize_labels(labels)

    # Increment bucket counters
    Enum.each(@histogram_buckets, fn bucket ->
      if value <= bucket do
        bucket_key = {:histogram_bucket, name, labels, bucket}
        try do
          :ets.update_counter(@table, bucket_key, {2, 1})
        catch
          :error, :badarg -> :ets.insert_new(@table, {bucket_key, 1})
        end
      end
    end)

    # +Inf bucket always incremented
    inf_key = {:histogram_bucket, name, labels, :inf}
    try do
      :ets.update_counter(@table, inf_key, {2, 1})
    catch
      :error, :badarg -> :ets.insert_new(@table, {inf_key, 1})
    end

    # Sum
    sum_key = {:histogram_sum, name, labels}
    try do
      # Can't use update_counter for floats, use insert with read-modify-write
      case :ets.lookup(@table, sum_key) do
        [{^sum_key, current}] -> :ets.insert(@table, {sum_key, current + value})
        [] -> :ets.insert(@table, {sum_key, value})
      end
    catch
      _ -> :ets.insert(@table, {sum_key, value})
    end

    # Count
    count_key = {:histogram_count, name, labels}
    try do
      :ets.update_counter(@table, count_key, {2, 1})
    catch
      :error, :badarg -> :ets.insert_new(@table, {count_key, 1})
    end
  end

  @doc "Get the current value of a counter or gauge."
  def get(type, name, labels \\ %{}) do
    key = {type, name, normalize_labels(labels)}
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  @doc "Format all metrics as Prometheus text exposition format."
  def format_prometheus do
    entries = :ets.tab2list(@table)

    # Group by metric name and type
    {counters, gauges, histograms} = group_entries(entries)

    lines = []

    # Counters
    lines = lines ++ format_metric_group("counter", counters)

    # Gauges
    lines = lines ++ format_metric_group("gauge", gauges)

    # Histograms
    lines = lines ++ format_histograms(histograms)

    Enum.join(lines, "\n") <> "\n"
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])
    Logger.info("[Hub.Metrics] ETS table :hub_metrics created")

    attach_telemetry_handlers()

    {:ok, %{}}
  end

  # ── Telemetry Handlers ─────────────────────────────────────

  defp attach_telemetry_handlers do
    handlers = [
      {"hub-metrics-channel-join", [:hub, :channel, :join], &handle_channel_join/4},
      {"hub-metrics-channel-leave", [:hub, :channel, :leave], &handle_channel_leave/4},
      {"hub-metrics-message-sent", [:hub, :message, :sent], &handle_message_sent/4},
      {"hub-metrics-task-submitted", [:hub, :task, :submitted], &handle_task_submitted/4},
      {"hub-metrics-task-completed", [:hub, :task, :completed], &handle_task_completed/4},
      {"hub-metrics-task-failed", [:hub, :task, :failed], &handle_task_failed/4},
      {"hub-metrics-memory-write", [:hub, :memory, :write], &handle_memory_write/4},
      {"hub-metrics-file-upload", [:hub, :file, :upload], &handle_file_upload/4},
      {"hub-metrics-webhook-delivered", [:hub, :webhook, :delivered], &handle_webhook_delivered/4},
      {"hub-metrics-auth-success", [:hub, :auth, :success], &handle_auth_success/4},
      {"hub-metrics-auth-failure", [:hub, :auth, :failure], &handle_auth_failure/4}
    ]

    Enum.each(handlers, fn {id, event, handler} ->
      :telemetry.attach(id, event, handler, nil)
    end)

    Logger.info("[Hub.Metrics] Attached #{length(handlers)} telemetry handlers")
  end

  # ── Event Handlers ─────────────────────────────────────────

  defp handle_channel_join(_event, _measurements, metadata, _config) do
    fleet_id = Map.get(metadata, :fleet_id, "unknown")
    inc("ringforge_connected_agents_total", %{fleet_id: fleet_id})
    gauge_inc("ringforge_connected_agents", %{fleet_id: fleet_id})
  end

  defp handle_channel_leave(_event, _measurements, metadata, _config) do
    fleet_id = Map.get(metadata, :fleet_id, "unknown")
    gauge_dec("ringforge_connected_agents", %{fleet_id: fleet_id})
  end

  defp handle_message_sent(_event, _measurements, metadata, _config) do
    fleet_id = Map.get(metadata, :fleet_id, "unknown")
    inc("ringforge_messages_total", %{fleet_id: fleet_id})
  end

  defp handle_task_submitted(_event, _measurements, metadata, _config) do
    fleet_id = Map.get(metadata, :fleet_id, "unknown")
    inc("ringforge_tasks_total", %{fleet_id: fleet_id, status: "submitted"})
  end

  defp handle_task_completed(_event, measurements, metadata, _config) do
    fleet_id = Map.get(metadata, :fleet_id, "unknown")
    inc("ringforge_tasks_total", %{fleet_id: fleet_id, status: "completed"})

    if duration_ms = Map.get(measurements, :duration_ms) do
      histogram_observe("ringforge_task_duration_seconds", %{fleet_id: fleet_id}, duration_ms / 1000)
    end
  end

  defp handle_task_failed(_event, _measurements, metadata, _config) do
    fleet_id = Map.get(metadata, :fleet_id, "unknown")
    inc("ringforge_tasks_total", %{fleet_id: fleet_id, status: "failed"})
  end

  defp handle_memory_write(_event, _measurements, metadata, _config) do
    fleet_id = Map.get(metadata, :fleet_id, "unknown")
    operation = Map.get(metadata, :operation, "write")
    inc("ringforge_memory_operations_total", %{fleet_id: fleet_id, operation: operation})
  end

  defp handle_file_upload(_event, _measurements, _metadata, _config) do
    inc("ringforge_file_uploads_total")
  end

  defp handle_webhook_delivered(_event, _measurements, metadata, _config) do
    status = Map.get(metadata, :status, "unknown")
    inc("ringforge_webhook_deliveries_total", %{status: status})
  end

  defp handle_auth_success(_event, _measurements, metadata, _config) do
    method = Map.get(metadata, :method, "unknown")
    inc("ringforge_auth_total", %{result: "success", method: method})
  end

  defp handle_auth_failure(_event, _measurements, metadata, _config) do
    method = Map.get(metadata, :method, "unknown")
    inc("ringforge_auth_total", %{result: "failure", method: method})
  end

  # ── Formatting Helpers ─────────────────────────────────────

  defp normalize_labels(labels) when is_map(labels) do
    labels
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp group_entries(entries) do
    Enum.reduce(entries, {%{}, %{}, %{}}, fn
      {{:counter, name, labels}, value}, {counters, gauges, histograms} ->
        {Map.update(counters, name, [{labels, value}], &[{labels, value} | &1]), gauges, histograms}

      {{:gauge, name, labels}, value}, {counters, gauges, histograms} ->
        {counters, Map.update(gauges, name, [{labels, value}], &[{labels, value} | &1]), histograms}

      {{:histogram_bucket, name, labels, bucket}, value}, {counters, gauges, histograms} ->
        key = {name, labels}
        histograms = Map.update(histograms, key, %{buckets: [{bucket, value}]}, fn h ->
          Map.update(h, :buckets, [{bucket, value}], &[{bucket, value} | &1])
        end)
        {counters, gauges, histograms}

      {{:histogram_sum, name, labels}, value}, {counters, gauges, histograms} ->
        key = {name, labels}
        histograms = Map.update(histograms, key, %{sum: value}, &Map.put(&1, :sum, value))
        {counters, gauges, histograms}

      {{:histogram_count, name, labels}, value}, {counters, gauges, histograms} ->
        key = {name, labels}
        histograms = Map.update(histograms, key, %{count: value}, &Map.put(&1, :count, value))
        {counters, gauges, histograms}

      _, acc -> acc
    end)
  end

  defp format_metric_group(type, metrics) do
    Enum.flat_map(metrics, fn {name, label_values} ->
      [
        "# TYPE #{name} #{type}"
        | Enum.map(label_values, fn {labels, value} ->
            format_line(name, labels, value)
          end)
      ]
    end)
  end

  defp format_histograms(histograms) do
    histograms
    |> Enum.group_by(fn {{name, _labels}, _data} -> name end)
    |> Enum.flat_map(fn {name, entries} ->
      [
        "# TYPE #{name} histogram"
        | Enum.flat_map(entries, fn {{_name, labels}, data} ->
            buckets = Map.get(data, :buckets, []) |> Enum.sort_by(fn
              {:inf, _} -> :infinity
              {b, _} -> b
            end)

            bucket_lines = Enum.map(buckets, fn {bucket, count} ->
              le = if bucket == :inf, do: "+Inf", else: to_string(bucket)
              format_line("#{name}_bucket", [{"le", le} | labels], count)
            end)

            sum_line = format_line("#{name}_sum", labels, Map.get(data, :sum, 0))
            count_line = format_line("#{name}_count", labels, Map.get(data, :count, 0))

            bucket_lines ++ [sum_line, count_line]
          end)
      ]
    end)
  end

  defp format_line(name, [], value), do: "#{name} #{format_value(value)}"
  defp format_line(name, labels, value) do
    label_str = labels
    |> Enum.map(fn {k, v} -> ~s(#{k}="#{v}") end)
    |> Enum.join(",")
    ~s(#{name}{#{label_str}} #{format_value(value)})
  end

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 6)
  defp format_value(v), do: to_string(v)
end
