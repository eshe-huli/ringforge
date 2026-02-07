defmodule Hub.MetricsController do
  @moduledoc """
  `/metrics` endpoint that returns Prometheus-compatible text format.

  Exposes both BEAM system metrics and Hub application metrics
  (tracked via Hub.Metrics ETS-backed counters).
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
      vm_io_metrics(),
      hub_info_metrics(),
      # Application metrics from Hub.Metrics ETS
      [Hub.Metrics.format_prometheus()]
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # ── BEAM Memory ────────────────────────────────────────────

  defp vm_memory_metrics do
    memory = :erlang.memory()

    [
      "# HELP beam_memory_bytes Memory allocated by the Erlang VM.",
      "# TYPE beam_memory_bytes gauge",
      prom("beam_memory_bytes", %{type: "total"}, Keyword.get(memory, :total, 0)),
      prom("beam_memory_bytes", %{type: "processes"}, Keyword.get(memory, :processes, 0)),
      prom("beam_memory_bytes", %{type: "binary"}, Keyword.get(memory, :binary, 0)),
      prom("beam_memory_bytes", %{type: "ets"}, Keyword.get(memory, :ets, 0)),
      prom("beam_memory_bytes", %{type: "atom"}, Keyword.get(memory, :atom, 0)),
      prom("beam_memory_bytes", %{type: "code"}, Keyword.get(memory, :code, 0)),
      prom("beam_memory_bytes", %{type: "system"}, Keyword.get(memory, :system, 0))
    ]
  end

  # ── BEAM System Counts ─────────────────────────────────────

  defp vm_system_metrics do
    [
      "# HELP beam_process_count Number of processes currently existing.",
      "# TYPE beam_process_count gauge",
      prom("beam_process_count", %{}, :erlang.system_info(:process_count)),
      "# HELP beam_atom_count Number of atoms currently existing.",
      "# TYPE beam_atom_count gauge",
      prom("beam_atom_count", %{}, :erlang.system_info(:atom_count)),
      "# HELP beam_port_count Number of ports currently existing.",
      "# TYPE beam_port_count gauge",
      prom("beam_port_count", %{}, :erlang.system_info(:port_count))
    ]
  end

  # ── Run Queues ─────────────────────────────────────────────

  defp vm_run_queue_metrics do
    run_queues = :erlang.statistics(:run_queue_lengths_all)
    total = Enum.sum(run_queues)
    cpu = run_queues |> Enum.drop(-1) |> Enum.sum()
    io = List.last(run_queues) || 0

    [
      "# HELP beam_run_queue_lengths Total run queue lengths.",
      "# TYPE beam_run_queue_lengths gauge",
      prom("beam_run_queue_lengths", %{kind: "total"}, total),
      prom("beam_run_queue_lengths", %{kind: "cpu"}, cpu),
      prom("beam_run_queue_lengths", %{kind: "io"}, io)
    ]
  end

  # ── Scheduler utilization ──────────────────────────────────

  defp vm_scheduler_metrics do
    scheduler_count = :erlang.system_info(:schedulers_online)

    [
      "# HELP beam_scheduler_utilization Number of schedulers online.",
      "# TYPE beam_scheduler_utilization gauge",
      prom("beam_scheduler_utilization", %{}, scheduler_count)
    ]
  end

  # ── I/O bytes ──────────────────────────────────────────────

  defp vm_io_metrics do
    {{:input, input}, {:output, output}} = :erlang.statistics(:io)

    [
      "# HELP beam_io_bytes_total Total I/O bytes.",
      "# TYPE beam_io_bytes_total counter",
      prom("beam_io_bytes_total", %{direction: "in"}, input),
      prom("beam_io_bytes_total", %{direction: "out"}, output)
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
