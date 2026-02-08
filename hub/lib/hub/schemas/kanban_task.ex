defmodule Hub.Schemas.KanbanTask do
  @moduledoc """
  Persistent kanban task schema for AI-native task management.

  Unlike the ephemeral ETS-based Hub.Task (for real-time coordination),
  kanban tasks are database-persisted and flow through lanes:

      backlog → ready → in_progress → review → done

  Tasks can be scoped to fleet, squad, or individual agent level.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @lanes ~w(backlog ready in_progress blocked review done archived cancelled)
  @priorities ~w(critical high medium low)
  @effort_levels ~w(trivial small medium large epic)
  @scopes ~w(fleet squad agent)

  def lanes, do: @lanes
  def priorities, do: @priorities
  def effort_levels, do: @effort_levels

  schema "kanban_tasks" do
    field :task_id, :string              # "T-001" human-readable
    field :title, :string
    field :description, :string
    field :lane, :string, default: "backlog"
    field :priority, :string, default: "medium"
    field :effort, :string, default: "medium"
    field :requires_capabilities, {:array, :string}, default: []
    field :depends_on, {:array, :string}, default: []       # task_ids
    field :blocked_by, {:array, :string}, default: []       # task_ids or free text
    field :acceptance_criteria, {:array, :string}, default: []
    field :context_refs, {:array, :string}, default: []     # memory keys, file refs
    field :tags, {:array, :string}, default: []
    field :progress, :string                                 # free text progress note
    field :progress_pct, :integer, default: 0               # 0-100
    field :result, :string                                   # completion result/summary
    field :deadline, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :estimated_minutes, :integer
    field :actual_minutes, :integer
    field :metadata, :map, default: %{}

    # Scope
    field :scope, :string, default: "fleet"  # "fleet", "squad", "agent"

    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :squad, Hub.Groups.Group      # nil for fleet-level tasks
    belongs_to :tenant, Hub.Auth.Tenant

    # People
    field :created_by, :string               # agent_id
    field :assigned_to, :string              # agent_id (nil = unassigned)
    field :reviewed_by, :string              # agent_id

    # Ordering
    field :position, :integer, default: 0    # sort order within lane

    has_many :history, Hub.Schemas.KanbanTaskHistory

    timestamps()
  end

  @required_fields [:title, :fleet_id, :tenant_id, :created_by]
  @cast_fields [
    :task_id, :title, :description, :lane, :priority, :effort,
    :requires_capabilities, :depends_on, :blocked_by, :acceptance_criteria,
    :context_refs, :tags, :progress, :progress_pct, :result,
    :deadline, :started_at, :completed_at, :estimated_minutes, :actual_minutes,
    :metadata, :scope, :fleet_id, :squad_id, :tenant_id,
    :created_by, :assigned_to, :reviewed_by, :position
  ]

  def changeset(task, attrs) do
    task
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:lane, @lanes)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:effort, @effort_levels)
    |> validate_inclusion(:scope, @scopes)
    |> validate_number(:progress_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:task_id)
  end

  @doc "Changeset for lane transitions only."
  def move_changeset(task, attrs) do
    task
    |> cast(attrs, [:lane, :started_at, :completed_at, :blocked_by])
    |> validate_inclusion(:lane, @lanes)
  end

  @doc "Changeset for progress updates."
  def progress_changeset(task, attrs) do
    task
    |> cast(attrs, [:progress, :progress_pct])
    |> validate_number(:progress_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  @doc "Changeset for assignment updates."
  def assign_changeset(task, attrs) do
    task
    |> cast(attrs, [:assigned_to, :lane, :started_at])
  end

  @doc "Serialize to a JSON-friendly map for wire protocol."
  def to_map(%__MODULE__{} = t) do
    %{
      "id" => t.id,
      "task_id" => t.task_id,
      "title" => t.title,
      "description" => t.description,
      "lane" => t.lane,
      "priority" => t.priority,
      "effort" => t.effort,
      "requires_capabilities" => t.requires_capabilities,
      "depends_on" => t.depends_on,
      "blocked_by" => t.blocked_by,
      "acceptance_criteria" => t.acceptance_criteria,
      "context_refs" => t.context_refs,
      "tags" => t.tags,
      "progress" => t.progress,
      "progress_pct" => t.progress_pct,
      "result" => t.result,
      "deadline" => t.deadline && DateTime.to_iso8601(t.deadline),
      "started_at" => t.started_at && DateTime.to_iso8601(t.started_at),
      "completed_at" => t.completed_at && DateTime.to_iso8601(t.completed_at),
      "estimated_minutes" => t.estimated_minutes,
      "actual_minutes" => t.actual_minutes,
      "metadata" => t.metadata,
      "scope" => t.scope,
      "fleet_id" => t.fleet_id,
      "squad_id" => t.squad_id,
      "created_by" => t.created_by,
      "assigned_to" => t.assigned_to,
      "reviewed_by" => t.reviewed_by,
      "position" => t.position,
      "inserted_at" => t.inserted_at && NaiveDateTime.to_iso8601(t.inserted_at),
      "updated_at" => t.updated_at && NaiveDateTime.to_iso8601(t.updated_at)
    }
  end
end
