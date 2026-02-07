defmodule Hub.Quota do
  @moduledoc """
  ETS-backed quota tracking and enforcement for Ringforge tenants.

  Tracks usage of metered resources (connected agents, messages, memory
  entries, fleets) against plan limits. The GenServer owns an ETS table
  `:hub_quotas` that stores `{{tenant_id, resource}, count, limit}` tuples.

  On startup, tenant plans are loaded from the database and limits are
  initialized. A daily timer resets `messages_today` counters at midnight UTC.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Auth.Tenant

  @table :hub_quotas
  @idempotency_table :hub_idempotency
  @idempotency_ttl_ms 300_000  # 5 minutes
  @idempotency_cleanup_ms 300_000  # 5 minutes

  @plan_limits %{
    "free" => %{
      messages_today: 10_000,
      memory_entries: 1_000,
      connected_agents: 5,
      fleets: 1
    },
    "team" => %{
      messages_today: 500_000,
      memory_entries: 100_000,
      connected_agents: 50,
      fleets: 10
    },
    "enterprise" => %{
      messages_today: :unlimited,
      memory_entries: :unlimited,
      connected_agents: :unlimited,
      fleets: :unlimited
    }
  }

  # ── Public API ─────────────────────────────────────────────

  @doc "Start the Quota GenServer."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Increment a resource counter for a tenant.

  Returns `{:ok, current_count}` if within quota,
  or `{:error, :quota_exceeded}` if the limit would be exceeded.
  Also returns quota warning metadata when usage crosses 80% or 95%.
  """
  @spec increment(String.t(), atom()) :: {:ok, non_neg_integer()} | {:error, :quota_exceeded}
  def increment(tenant_id, resource) do
    key = {tenant_id, resource}

    case :ets.lookup(@table, key) do
      [{^key, count, :unlimited}] ->
        :ets.update_element(@table, key, {2, count + 1})
        {:ok, count + 1}

      [{^key, count, limit}] when count < limit ->
        :ets.update_element(@table, key, {2, count + 1})
        new_count = count + 1
        maybe_warn(tenant_id, resource, new_count, limit)
        {:ok, new_count}

      [{^key, _count, _limit}] ->
        {:error, :quota_exceeded}

      [] ->
        # No entry — initialize from plan then retry
        GenServer.call(__MODULE__, {:ensure_tenant, tenant_id})
        increment(tenant_id, resource)
    end
  end

  @doc "Decrement a resource counter (floors at 0)."
  @spec decrement(String.t(), atom()) :: :ok
  def decrement(tenant_id, resource) do
    key = {tenant_id, resource}

    case :ets.lookup(@table, key) do
      [{^key, count, _limit}] when count > 0 ->
        :ets.update_element(@table, key, {2, count - 1})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Check current usage for a single resource.

  Returns `{:ok, %{used: N, limit: M, remaining: R}}` or `{:ok, :unlimited}`.
  """
  @spec check(String.t(), atom()) :: {:ok, map() | :unlimited}
  def check(tenant_id, resource) do
    key = {tenant_id, resource}

    case :ets.lookup(@table, key) do
      [{^key, _count, :unlimited}] ->
        {:ok, :unlimited}

      [{^key, count, limit}] ->
        {:ok, %{used: count, limit: limit, remaining: max(limit - count, 0)}}

      [] ->
        GenServer.call(__MODULE__, {:ensure_tenant, tenant_id})
        check(tenant_id, resource)
    end
  end

  @doc "Returns all resource usage for a tenant."
  @spec get_usage(String.t()) :: map()
  def get_usage(tenant_id) do
    resources = [:messages_today, :memory_entries, :connected_agents, :fleets]

    Map.new(resources, fn resource ->
      key = {tenant_id, resource}

      usage =
        case :ets.lookup(@table, key) do
          [{^key, count, :unlimited}] ->
            %{used: count, limit: :unlimited}

          [{^key, count, limit}] ->
            %{used: count, limit: limit}

          [] ->
            %{used: 0, limit: 0}
        end

      {resource, usage}
    end)
  end

  @doc "Reset the `messages_today` counter for a tenant."
  @spec reset_daily(String.t()) :: :ok
  def reset_daily(tenant_id) do
    key = {tenant_id, :messages_today}

    case :ets.lookup(@table, key) do
      [{^key, _count, _limit}] ->
        :ets.update_element(@table, key, {2, 0})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Load and apply plan limits for a tenant."
  @spec set_plan_limits(String.t(), String.t()) :: :ok
  def set_plan_limits(tenant_id, plan) do
    limits = Map.get(@plan_limits, plan, @plan_limits["free"])

    Enum.each(limits, fn {resource, limit} ->
      key = {tenant_id, resource}

      case :ets.lookup(@table, key) do
        [{^key, count, _old_limit}] ->
          :ets.insert(@table, {key, count, limit})

        [] ->
          :ets.insert(@table, {key, 0, limit})
      end
    end)

    :ok
  end

  @doc "Return plan limits map (for external use)."
  @spec plan_limits() :: map()
  def plan_limits, do: @plan_limits

  # ── Idempotency API ───────────────────────────────────────

  @doc """
  Check the idempotency cache for a previously-seen key.

  Returns `{:hit, cached_response}` if the key exists and hasn't expired,
  or `:miss` if no entry is found.
  """
  @spec idempotency_check(String.t()) :: {:hit, term()} | :miss
  def idempotency_check(key) when is_binary(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@idempotency_table, key) do
      [{^key, response, expires_at}] when expires_at > now ->
        {:hit, response}

      [{^key, _response, _expires_at}] ->
        # Expired — delete lazily
        :ets.delete(@idempotency_table, key)
        :miss

      [] ->
        :miss
    end
  end

  @doc """
  Store a response in the idempotency cache with a 5-minute TTL.
  """
  @spec idempotency_store(String.t(), term()) :: :ok
  def idempotency_store(key, response) when is_binary(key) do
    expires_at = System.monotonic_time(:millisecond) + @idempotency_ttl_ms
    :ets.insert(@idempotency_table, {key, response, expires_at})
    :ok
  end

  # ── GenServer Callbacks ────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[Hub.Quota] ETS table :hub_quotas created")

    # Create rate limit table (owned by this long-lived GenServer)
    Hub.Plugs.RateLimit.init_table()
    Logger.info("[Hub.Quota] ETS table :hub_rate_limits created")

    # Create idempotency cache table
    :ets.new(@idempotency_table, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[Hub.Quota] ETS table :hub_idempotency created")

    # Load all tenants and initialize their quotas
    load_all_tenants()

    # Schedule daily reset at midnight UTC
    schedule_daily_reset()

    # Schedule periodic idempotency cache cleanup
    schedule_idempotency_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:ensure_tenant, tenant_id}, _from, state) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{plan: plan} ->
        set_plan_limits(tenant_id, plan)
        {:reply, :ok, state}

      nil ->
        # Unknown tenant — set free limits as fallback
        set_plan_limits(tenant_id, "free")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:cleanup_idempotency, state) do
    now = System.monotonic_time(:millisecond)
    expired_keys =
      :ets.foldl(
        fn
          {key, _response, expires_at}, acc when expires_at <= now -> [key | acc]
          _, acc -> acc
        end,
        [],
        @idempotency_table
      )

    Enum.each(expired_keys, &:ets.delete(@idempotency_table, &1))

    if expired_keys != [] do
      Logger.debug("[Hub.Quota] Cleaned #{length(expired_keys)} expired idempotency entries")
    end

    schedule_idempotency_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:daily_reset, state) do
    Logger.info("[Hub.Quota] Running daily reset of messages_today counters")

    # Reset messages_today for all tenants
    :ets.foldl(
      fn
        {{tenant_id, :messages_today}, _count, limit}, acc ->
          :ets.insert(@table, {{tenant_id, :messages_today}, 0, limit})
          acc

        _, acc ->
          acc
      end,
      :ok,
      @table
    )

    schedule_daily_reset()
    {:noreply, state}
  end

  # ── Private Helpers ────────────────────────────────────────

  defp load_all_tenants do
    tenants = Repo.all(from(t in Tenant, select: {t.id, t.plan}))

    Enum.each(tenants, fn {tenant_id, plan} ->
      set_plan_limits(tenant_id, plan || "free")
    end)

    Logger.info("[Hub.Quota] Loaded quotas for #{length(tenants)} tenant(s)")
  end

  defp schedule_daily_reset do
    now = DateTime.utc_now()

    # Next midnight UTC
    tomorrow =
      now
      |> DateTime.to_date()
      |> Date.add(1)

    midnight = DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")
    ms_until = DateTime.diff(midnight, now, :millisecond)
    Process.send_after(self(), :daily_reset, ms_until)
  end

  defp schedule_idempotency_cleanup do
    Process.send_after(self(), :cleanup_idempotency, @idempotency_cleanup_ms)
  end

  defp maybe_warn(tenant_id, resource, count, limit) when is_integer(limit) and limit > 0 do
    pct = count / limit * 100

    cond do
      pct >= 95 and (count - 1) / limit * 100 < 95 ->
        broadcast_quota_warning(tenant_id, resource, count, limit)

      pct >= 80 and (count - 1) / limit * 100 < 80 ->
        broadcast_quota_warning(tenant_id, resource, count, limit)

      true ->
        :ok
    end
  end

  defp maybe_warn(_tenant_id, _resource, _count, _limit), do: :ok

  defp broadcast_quota_warning(tenant_id, resource, used, limit) do
    msg = %{
      "type" => "system",
      "event" => "quota_warning",
      "payload" => %{
        "resource" => Atom.to_string(resource),
        "used" => used,
        "limit" => limit
      }
    }

    # Broadcast to all fleets for this tenant
    fleets = Repo.all(from(f in Hub.Auth.Fleet, where: f.tenant_id == ^tenant_id, select: f.id))

    Enum.each(fleets, fn fleet_id ->
      Phoenix.PubSub.broadcast(Hub.PubSub, "fleet:#{fleet_id}", {:quota_warning, msg})
    end)

    Logger.info("[Hub.Quota] Warning: #{resource} at #{used}/#{limit} for tenant #{tenant_id}")
  end
end
