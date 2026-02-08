defmodule Hub.Schemas.KanbanTaskHistory do
  @moduledoc """
  Tracks lane transitions for kanban tasks.

  Every time a task moves between lanes, a history entry is created,
  enabling velocity calculations, cycle time analysis, and audit trails.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kanban_task_history" do
    belongs_to :kanban_task, Hub.Schemas.KanbanTask
    field :from_lane, :string
    field :to_lane, :string
    field :changed_by, :string   # agent_id
    field :reason, :string

    timestamps()
  end

  def changeset(history, attrs) do
    history
    |> cast(attrs, [:kanban_task_id, :from_lane, :to_lane, :changed_by, :reason])
    |> validate_required([:kanban_task_id, :to_lane, :changed_by])
  end

  def to_map(%__MODULE__{} = h) do
    %{
      "id" => h.id,
      "from_lane" => h.from_lane,
      "to_lane" => h.to_lane,
      "changed_by" => h.changed_by,
      "reason" => h.reason,
      "timestamp" => h.inserted_at && NaiveDateTime.to_iso8601(h.inserted_at)
    }
  end
end
