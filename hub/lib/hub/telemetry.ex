defmodule Hub.Telemetry do
  @moduledoc """
  Telemetry supervisor for the Hub.

  Defines metrics and polls VM stats. Implements Law 7:
  "Events & observables everywhere."

  ## Event Prefixes

      [:hub, :channel, :join]      — agent connects
      [:hub, :channel, :leave]     — agent disconnects
      [:hub, :message, :sent]      — message sent
      [:hub, :task, :submitted]    — task submitted
      [:hub, :task, :completed]    — task completed
      [:hub, :task, :failed]       — task failed
      [:hub, :memory, :write]      — memory write
      [:hub, :file, :upload]       — file uploaded
      [:hub, :webhook, :delivered] — webhook delivered
      [:hub, :auth, :success]      — auth success
      [:hub, :auth, :failure]      — auth failure

  All events carry at minimum `%{system_time: integer}` in measurements
  and relevant context in metadata.
  """
  use Supervisor

  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Returns the list of all Hub telemetry metrics definitions."
  def metrics do
    [
      # ── Channel lifecycle ──────────────────────────────────
      counter("hub.channel.join.count", tags: [:fleet_id]),
      counter("hub.channel.leave.count", tags: [:fleet_id]),

      # ── Messages ───────────────────────────────────────────
      counter("hub.message.sent.count", tags: [:fleet_id]),

      # ── Tasks ──────────────────────────────────────────────
      counter("hub.task.submitted.count", tags: [:fleet_id]),
      counter("hub.task.completed.count", tags: [:fleet_id]),
      counter("hub.task.failed.count", tags: [:fleet_id]),
      distribution("hub.task.duration",
        unit: {:native, :millisecond},
        tags: [:fleet_id]
      ),

      # ── Memory ─────────────────────────────────────────────
      counter("hub.memory.write.count", tags: [:fleet_id]),

      # ── Files ──────────────────────────────────────────────
      counter("hub.file.upload.count", tags: [:fleet_id]),

      # ── Webhooks ───────────────────────────────────────────
      counter("hub.webhook.delivered.count", tags: [:status]),

      # ── Auth ───────────────────────────────────────────────
      counter("hub.auth.success.count", tags: [:method]),
      counter("hub.auth.failure.count", tags: [:method]),

      # ── Node lifecycle (legacy) ────────────────────────────
      counter("hub.node.join.count", tags: [:node_id]),
      counter("hub.node.leave.count", tags: [:node_id]),

      # ── Sync operations ────────────────────────────────────
      counter("hub.sync.push.count", tags: [:node_id]),
      counter("hub.sync.pull.count", tags: [:node_id]),
      distribution("hub.sync.push.duration",
        unit: {:native, :millisecond},
        tags: [:node_id]
      ),
      distribution("hub.sync.pull.duration",
        unit: {:native, :millisecond},
        tags: [:node_id]
      ),
      summary("hub.sync.push.payload_size", tags: [:node_id]),
      summary("hub.sync.pull.payload_size", tags: [:node_id]),

      # ── Blob store ─────────────────────────────────────────
      counter("hub.blob.put.count", tags: [:node_id]),
      counter("hub.blob.get.count", tags: [:node_id]),
      distribution("hub.blob.put.duration",
        unit: {:native, :millisecond},
        tags: [:node_id]
      ),
      distribution("hub.blob.get.duration",
        unit: {:native, :millisecond},
        tags: [:node_id]
      ),
      summary("hub.blob.put.size", tags: [:node_id]),

      # ── Doc store ──────────────────────────────────────────
      counter("hub.doc.put.count", tags: [:node_id]),
      counter("hub.doc.get.count", tags: [:node_id]),
      distribution("hub.doc.put.duration",
        unit: {:native, :millisecond},
        tags: [:node_id]
      ),
      distribution("hub.doc.get.duration",
        unit: {:native, :millisecond},
        tags: [:node_id]
      ),

      # ── VM metrics (polled) ────────────────────────────────
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.atom_count"),
      last_value("vm.system_counts.port_count")
    ]
  end

  # ── Convenience emit helpers ───────────────────────────────

  @doc "Execute a telemetry event with standard measurements."
  def execute(event_name, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new(measurements, :system_time, System.system_time())
    :telemetry.execute(event_name, measurements, metadata)
  end

  @doc "Span-based telemetry for timed operations."
  def span(event_name, metadata, fun) do
    :telemetry.span(event_name, metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  # ── Periodic measurements ──────────────────────────────────

  defp periodic_measurements do
    [
      # telemetry_poller built-in VM measurements
      {__MODULE__, :emit_vm_metrics, []}
    ]
  end

  @doc false
  def emit_vm_metrics do
    memory = :erlang.memory()

    :telemetry.execute([:vm, :memory], %{
      total: Keyword.get(memory, :total, 0),
      processes: Keyword.get(memory, :processes, 0),
      binary: Keyword.get(memory, :binary, 0),
      ets: Keyword.get(memory, :ets, 0)
    })

    :telemetry.execute([:vm, :system_counts], %{
      process_count: :erlang.system_info(:process_count),
      atom_count: :erlang.system_info(:atom_count),
      port_count: :erlang.system_info(:port_count)
    })

    run_queue = :erlang.statistics(:run_queue_lengths_all)
    total = Enum.sum(run_queue)
    cpu = run_queue |> Enum.drop(-1) |> Enum.sum()
    io = List.last(run_queue) || 0

    :telemetry.execute([:vm, :total_run_queue_lengths], %{
      total: total,
      cpu: cpu,
      io: io
    })
  end
end
