defmodule Hub.MetricsController do
  @moduledoc """
  Simple `/metrics` endpoint that returns Prometheus-compatible text format.

  Exposes VM stats and Hub telemetry counters as Prometheus gauges/counters.
  No external Prometheus library required — we build the text output directly
  from BEAM introspection.
  """
  use Phoenix.Controller, formats: [:text]

  def index(conn, _params) do
    metrics = build_metrics()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  defp build_metrics do
    [
      vm_memory_metrics(),
      vm_system_metrics(),
      vm_run_queue_metrics(),
      vm_scheduler_metrics(),
      hub_info_metrics()
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # ── VM Memory ──────────────────────────────────────────────

  defp vm_memory_metrics do
    memory = :erlang.memory()

    [
      "# HELP vm_memory_bytes_total Total memory allocated by the Erlang VM.",
      "# TYPE vm_memory_bytes_total gauge",
      prom("vm_memory_bytes_total", %{kind: "total"}, Keyword.get(memory, :total, 0)),
      prom("vm_memory_bytes_total", %{kind: "processes"}, Keyword.get(memory, :processes, 0)),
      prom("vm_memory_bytes_total", %{kind: "binary"}, Keyword.get(memory, :binary, 0)),
      prom("vm_memory_bytes_total", %{kind: "ets"}, Keyword.get(memory, :ets, 0)),
      prom("vm_memory_bytes_total", %{kind: "atom"}, Keyword.get(memory, :atom, 0)),
      prom("vm_memory_bytes_total", %{kind: "code"}, Keyword.get(memory, :code, 0)),
      prom("vm_memory_bytes_total", %{kind: "system"}, Keyword.get(memory, :system, 0))
    ]
  end

  # ── VM System Counts ───────────────────────────────────────

  defp vm_system_metrics do
    [
      "# HELP vm_process_count Number of processes currently existing.",
      "# TYPE vm_process_count gauge",
      prom("vm_process_count", %{}, :erlang.system_info(:process_count)),
      "# HELP vm_atom_count Number of atoms currently existing.",
      "# TYPE vm_atom_count gauge",
      prom("vm_atom_count", %{}, :erlang.system_info(:atom_count)),
      "# HELP vm_port_count Number of ports currently existing.",
      "# TYPE vm_port_count gauge",
      prom("vm_port_count", %{}, :erlang.system_info(:port_count))
    ]
  end

  # ── Run Queues ─────────────────────────────────────────────

  defp vm_run_queue_metrics do
    run_queues = :erlang.statistics(:run_queue_lengths_all)
    total = Enum.sum(run_queues)
    cpu = run_queues |> Enum.drop(-1) |> Enum.sum()
    io = List.last(run_queues) || 0

    [
      "# HELP vm_run_queue_lengths Total run queue lengths.",
      "# TYPE vm_run_queue_lengths gauge",
      prom("vm_run_queue_lengths", %{kind: "total"}, total),
      prom("vm_run_queue_lengths", %{kind: "cpu"}, cpu),
      prom("vm_run_queue_lengths", %{kind: "io"}, io)
    ]
  end

  # ── Scheduler utilization ──────────────────────────────────

  defp vm_scheduler_metrics do
    scheduler_count = :erlang.system_info(:schedulers_online)

    [
      "# HELP vm_schedulers_online Number of schedulers online.",
      "# TYPE vm_schedulers_online gauge",
      prom("vm_schedulers_online", %{}, scheduler_count)
    ]
  end

  # ── Hub info ───────────────────────────────────────────────

  defp hub_info_metrics do
    node_name = node() |> Atom.to_string()
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    [
      "# HELP hub_info Hub node information.",
      "# TYPE hub_info gauge",
      prom("hub_info", %{node: node_name, version: hub_version()}, 1),
      "# HELP hub_uptime_milliseconds Hub uptime in milliseconds.",
      "# TYPE hub_uptime_milliseconds gauge",
      prom("hub_uptime_milliseconds", %{}, uptime_ms)
    ]
  end

  # ── Helpers ────────────────────────────────────────────────

  defp prom(name, labels, value) when map_size(labels) == 0 do
    "#{name} #{value}"
  end

  defp prom(name, labels, value) do
    label_str =
      labels
      |> Enum.map(fn {k, v} -> ~s(#{k}="#{v}") end)
      |> Enum.join(",")

    ~s(#{name}{#{label_str}} #{value})
  end

  defp hub_version do
    case :application.get_key(:hub, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "unknown"
    end
  end
end
