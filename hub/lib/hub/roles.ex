defmodule Hub.Roles do
  @moduledoc """
  Context for agent role templates — CRUD, predefined seeding, and assignment.

  Role templates define system prompts, capabilities, constraints, and
  context injection behavior for agents. Predefined templates are system-wide;
  custom templates belong to a tenant.
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Schemas.RoleTemplate
  alias Hub.Auth.Agent
  alias Hub.Roles.Predefined

  require Logger

  # ── Seed ────────────────────────────────────────────────────

  @doc """
  Seed or update all predefined role templates.
  Called on application startup.
  """
  def seed_predefined_roles do
    Predefined.all()
    |> Enum.each(fn role_attrs ->
      existing =
        from(r in RoleTemplate,
          where: r.slug == ^role_attrs.slug and is_nil(r.tenant_id)
        )
        |> Repo.one()

      case existing do
        nil ->
          %RoleTemplate{}
          |> RoleTemplate.changeset(Map.put(role_attrs, :is_predefined, true))
          |> Repo.insert()
          |> case do
            {:ok, _} -> Logger.info("Seeded role: #{role_attrs.slug}")
            {:error, cs} -> Logger.warning("Failed to seed #{role_attrs.slug}: #{inspect(cs.errors)}")
          end

        existing ->
          existing
          |> RoleTemplate.changeset(Map.drop(role_attrs, [:slug]))
          |> Repo.update()
          |> case do
            {:ok, _} -> :ok
            {:error, cs} -> Logger.warning("Failed to update #{role_attrs.slug}: #{inspect(cs.errors)}")
          end
      end
    end)
  end

  # ── Query ───────────────────────────────────────────────────

  @doc """
  List all roles available to a tenant (predefined + custom).
  """
  def list_roles(tenant_id) do
    from(r in RoleTemplate,
      where: is_nil(r.tenant_id) or r.tenant_id == ^tenant_id,
      order_by: [desc: r.is_predefined, asc: r.name]
    )
    |> Repo.all()
  end

  @doc """
  List only predefined roles.
  """
  def list_predefined do
    from(r in RoleTemplate, where: r.is_predefined == true, order_by: [asc: r.name])
    |> Repo.all()
  end

  @doc """
  Get a role template by ID.
  """
  def get_role(id) do
    case Repo.get(RoleTemplate, id) do
      nil -> {:error, :not_found}
      role -> {:ok, role}
    end
  end

  @doc """
  Get a role by slug, scoped to tenant. Falls back to predefined if no custom match.
  """
  def get_role_by_slug(slug, tenant_id) do
    # Try tenant-specific first
    case Repo.get_by(RoleTemplate, slug: slug, tenant_id: tenant_id) do
      nil ->
        # Fall back to predefined
        case Repo.get_by(RoleTemplate, slug: slug, tenant_id: nil) do
          nil -> {:error, :not_found}
          role -> {:ok, role}
        end

      role ->
        {:ok, role}
    end
  end

  # ── CRUD ────────────────────────────────────────────────────

  @doc """
  Create a custom role template for a tenant.
  """
  def create_role(tenant_id, attrs) when is_map(attrs) do
    %RoleTemplate{}
    |> RoleTemplate.changeset(
      attrs
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:is_predefined, false)
    )
    |> Repo.insert()
  end

  @doc """
  Update a role template. Predefined templates cannot be modified.
  """
  def update_role(id, attrs) do
    with {:ok, role} <- get_role(id) do
      if role.is_predefined do
        {:error, :predefined_immutable}
      else
        role
        |> RoleTemplate.changeset(attrs)
        |> Repo.update()
      end
    end
  end

  @doc """
  Delete a custom role template. Predefined templates cannot be deleted.
  Unassigns all agents using this role first.
  """
  def delete_role(id) do
    with {:ok, role} <- get_role(id) do
      if role.is_predefined do
        {:error, :predefined_immutable}
      else
        # Unassign agents using this role
        from(a in Agent, where: a.role_template_id == ^id)
        |> Repo.update_all(set: [role_template_id: nil])

        Repo.delete(role)
      end
    end
  end

  # ── Assignment ──────────────────────────────────────────────

  @doc """
  Assign a role template to an agent.
  """
  def assign_role(agent_id, role_template_id) do
    with {:ok, _role} <- get_role(role_template_id),
         agent when not is_nil(agent) <- Repo.get_by(Agent, agent_id: agent_id) do
      agent
      |> Agent.changeset(%{role_template_id: role_template_id})
      |> Repo.update()
    else
      nil -> {:error, :agent_not_found}
      error -> error
    end
  end

  @doc """
  Assign a role by slug (convenience). Resolves slug to ID first.
  """
  def assign_role_by_slug(agent_id, slug, tenant_id) do
    with {:ok, role} <- get_role_by_slug(slug, tenant_id) do
      assign_role(agent_id, role.id)
    end
  end

  @doc """
  Remove role assignment from an agent.
  """
  def unassign_role(agent_id) do
    case Repo.get_by(Agent, agent_id: agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent ->
        agent
        |> Agent.changeset(%{role_template_id: nil})
        |> Repo.update()
    end
  end

  # ── Role Context ────────────────────────────────────────────

  @doc """
  Get the full role context for an agent. Returns nil if no role assigned.
  Used by ContextInjection to build message envelopes.
  """
  def agent_role_context(agent_id) do
    query =
      from a in Agent,
        where: a.agent_id == ^agent_id,
        join: r in RoleTemplate, on: a.role_template_id == r.id,
        select: %{
          role_slug: r.slug,
          role_name: r.name,
          system_prompt: r.system_prompt,
          capabilities: r.capabilities,
          constraints: r.constraints,
          tools_allowed: r.tools_allowed,
          escalation_rules: r.escalation_rules,
          respond_format: r.respond_format,
          respond_schema: r.respond_schema,
          injection_tier: r.context_injection_tier,
          agent_tier: a.context_tier
        }

    Repo.one(query)
  end

  @doc """
  Serialize a role template to a map for wire protocol responses.
  """
  def to_wire(%RoleTemplate{} = r) do
    %{
      id: r.id,
      slug: r.slug,
      name: r.name,
      system_prompt: r.system_prompt,
      capabilities: r.capabilities,
      constraints: r.constraints,
      tools_allowed: r.tools_allowed,
      escalation_rules: r.escalation_rules,
      context_injection_tier: r.context_injection_tier,
      respond_format: r.respond_format,
      respond_schema: r.respond_schema,
      is_predefined: r.is_predefined,
      metadata: r.metadata
    }
  end
end
