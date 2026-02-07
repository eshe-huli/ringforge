defmodule Hub.Auth.AgentSession do
  @moduledoc """
  Schema for agent session history.

  Tracks individual connection sessions for each agent, including
  connect/disconnect times and reasons. Used for observability
  and debugging connection issues.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_sessions_per_agent 50

  schema "agent_sessions" do
    field :connected_at, :utc_datetime
    field :disconnected_at, :utc_datetime
    field :disconnect_reason, :string
    field :ip_address, :string

    belongs_to :agent, Hub.Auth.Agent
    belongs_to :fleet, Hub.Auth.Fleet

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:agent_id, :fleet_id, :connected_at, :disconnected_at, :disconnect_reason, :ip_address])
    |> validate_required([:agent_id, :connected_at])
  end

  @doc "Maximum sessions retained per agent."
  def max_sessions, do: @max_sessions_per_agent

  @doc """
  Creates a new session record for an agent connection.
  """
  def start_session(agent_id, fleet_id, ip_address \\ nil) do
    attrs = %{
      agent_id: agent_id,
      fleet_id: fleet_id,
      connected_at: DateTime.utc_now() |> DateTime.truncate(:second),
      ip_address: ip_address
    }

    case %__MODULE__{} |> changeset(attrs) |> Hub.Repo.insert() do
      {:ok, session} ->
        # Prune old sessions async
        Task.start(fn -> prune_sessions(agent_id) end)
        {:ok, session}

      error ->
        error
    end
  end

  @doc """
  Ends a session by setting disconnected_at and reason.
  """
  def end_session(session_id, reason \\ "normal") when is_binary(session_id) do
    import Ecto.Query

    from(s in __MODULE__,
      where: s.id == ^session_id,
      update: [set: [
        disconnected_at: ^(DateTime.utc_now() |> DateTime.truncate(:second)),
        disconnect_reason: ^reason
      ]]
    )
    |> Hub.Repo.update_all([])

    :ok
  end

  @doc """
  Lists recent sessions for an agent.
  """
  def list_sessions(agent_id, limit \\ @max_sessions_per_agent) do
    import Ecto.Query

    from(s in __MODULE__,
      where: s.agent_id == ^agent_id,
      order_by: [desc: s.connected_at],
      limit: ^limit
    )
    |> Hub.Repo.all()
  end

  @doc """
  Prune sessions beyond the max limit for an agent.
  """
  def prune_sessions(agent_id) do
    import Ecto.Query

    # Get IDs to keep (most recent N)
    keep_ids =
      from(s in __MODULE__,
        where: s.agent_id == ^agent_id,
        order_by: [desc: s.connected_at],
        limit: ^@max_sessions_per_agent,
        select: s.id
      )
      |> Hub.Repo.all()

    if keep_ids != [] do
      from(s in __MODULE__,
        where: s.agent_id == ^agent_id and s.id not in ^keep_ids
      )
      |> Hub.Repo.delete_all()
    end

    :ok
  end

  @doc "Convert session to a map for API/dashboard display."
  def to_map(%__MODULE__{} = session) do
    %{
      id: session.id,
      connected_at: session.connected_at && DateTime.to_iso8601(session.connected_at),
      disconnected_at: session.disconnected_at && DateTime.to_iso8601(session.disconnected_at),
      disconnect_reason: session.disconnect_reason,
      ip_address: session.ip_address,
      duration_seconds: session_duration(session)
    }
  end

  defp session_duration(%{connected_at: c, disconnected_at: d}) when not is_nil(c) and not is_nil(d) do
    DateTime.diff(d, c, :second)
  end

  defp session_duration(%{connected_at: c}) when not is_nil(c) do
    DateTime.diff(DateTime.utc_now(), c, :second)
  end

  defp session_duration(_), do: nil
end
