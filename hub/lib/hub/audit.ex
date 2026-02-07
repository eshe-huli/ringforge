defmodule Hub.Audit do
  @moduledoc """
  Structured audit logging for all security-sensitive operations.

  Writes audit events to both Postgres (`audit_logs` table) for queryability
  and the EventBus for real-time streaming.

  ## Usage

      Hub.Audit.log("tenant.login", {"tenant", tenant.id}, nil, %{ip: ip})
      Hub.Audit.log("api_key.created", {"tenant", tenant_id}, {"api_key", key.id}, %{type: "live"})
      Hub.Audit.log("agent.registered", {"api_key", key.id}, {"agent", agent.agent_id}, %{fleet: fleet_id})

  All writes are async (fire-and-forget) to avoid blocking the caller.
  """

  require Logger

  alias Hub.Repo
  alias Hub.Schemas.AuditLog

  @doc """
  Log an audit event.

  ## Parameters

    - `action` — dot-separated action string (e.g., "tenant.login", "api_key.created")
    - `actor` — `{actor_type, actor_id}` tuple or `nil` for system actions
    - `target` — `{target_type, target_id}` tuple or `nil`
    - `metadata` — optional map with extra context

  ## Options in metadata

    - `:tenant_id` — tenant UUID (required for Postgres storage)
    - `:ip_address` — client IP address
    - `:fleet_id` — fleet UUID (for EventBus topic routing)
  """
  def log(action, actor, target \\ nil, metadata \\ %{})

  def log(action, actor, target, metadata) when is_binary(action) do
    {actor_type, actor_id} = normalize_actor(actor)
    {target_type, target_id} = normalize_target(target)

    tenant_id = Map.get(metadata, :tenant_id) || Map.get(metadata, "tenant_id")
    ip_address = Map.get(metadata, :ip_address) || Map.get(metadata, "ip_address")
    fleet_id = Map.get(metadata, :fleet_id) || Map.get(metadata, "fleet_id")

    # Strip internal keys from metadata before storage
    clean_meta =
      metadata
      |> Map.drop([:tenant_id, :ip_address, :fleet_id, "tenant_id", "ip_address", "fleet_id"])

    # Async write to Postgres
    Task.start(fn ->
      attrs = %{
        action: action,
        actor_type: actor_type,
        actor_id: to_string(actor_id),
        target_type: target_type,
        target_id: if(target_id, do: to_string(target_id)),
        tenant_id: tenant_id,
        ip_address: ip_address,
        metadata: clean_meta
      }

      case %AuditLog{} |> AuditLog.changeset(attrs) |> Repo.insert() do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.warning("[Audit] Failed to write audit log: #{inspect(changeset.errors)}")
      end
    end)

    # Async write to EventBus
    Task.start(fn ->
      bus_topic =
        if fleet_id do
          "rf.#{fleet_id}.audit"
        else
          "rf.system.audit"
        end

      Hub.EventBus.publish(bus_topic, %{
        "kind" => "audit",
        "action" => action,
        "actor_type" => actor_type,
        "actor_id" => to_string(actor_id),
        "target_type" => target_type,
        "target_id" => if(target_id, do: to_string(target_id)),
        "ip_address" => ip_address,
        "metadata" => clean_meta,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)

    :ok
  end

  def log(_, _, _, _), do: :ok

  # ── Query ──────────────────────────────────────────────────

  @doc "List audit logs for a tenant with optional filters."
  def list(tenant_id, opts \\ []) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    action = Keyword.get(opts, :action)
    actor_type = Keyword.get(opts, :actor_type)
    target_type = Keyword.get(opts, :target_type)
    since = Keyword.get(opts, :since)
    until_dt = Keyword.get(opts, :until)

    query =
      from(a in AuditLog,
        where: a.tenant_id == ^tenant_id,
        order_by: [desc: a.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query = if action, do: from(a in query, where: a.action == ^action), else: query
    query = if actor_type, do: from(a in query, where: a.actor_type == ^actor_type), else: query
    query = if target_type, do: from(a in query, where: a.target_type == ^target_type), else: query
    query = if since, do: from(a in query, where: a.inserted_at >= ^since), else: query
    query = if until_dt, do: from(a in query, where: a.inserted_at <= ^until_dt), else: query

    Repo.all(query)
  end

  @doc "Count audit logs for a tenant."
  def count(tenant_id) do
    import Ecto.Query
    Repo.one(from(a in AuditLog, where: a.tenant_id == ^tenant_id, select: count(a.id)))
  end

  # ── Private ────────────────────────────────────────────────

  defp normalize_actor(nil), do: {"system", "system"}
  defp normalize_actor({type, id}), do: {to_string(type), to_string(id)}
  defp normalize_actor(id) when is_binary(id), do: {"unknown", id}

  defp normalize_target(nil), do: {nil, nil}
  defp normalize_target({type, id}), do: {to_string(type), to_string(id)}
  defp normalize_target(id) when is_binary(id), do: {"unknown", id}
end
