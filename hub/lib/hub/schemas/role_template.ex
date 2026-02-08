defmodule Hub.Schemas.RoleTemplate do
  @moduledoc """
  Schema for role templates — reusable role definitions that can be assigned
  to agents to shape their behavior, system prompt, and context injection.

  Predefined (system) templates have `is_predefined: true` and `tenant_id: nil`.
  Custom templates belong to a specific tenant.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "role_templates" do
    field :slug, :string
    field :name, :string
    field :system_prompt, :string
    field :capabilities, {:array, :string}, default: []
    field :constraints, {:array, :string}, default: []
    field :tools_allowed, {:array, :string}, default: []
    field :escalation_rules, :string
    field :context_injection_tier, :string, default: "auto"
    field :respond_format, :string
    field :respond_schema, :map
    field :is_predefined, :boolean, default: false
    field :metadata, :map, default: %{}

    belongs_to :tenant, Hub.Auth.Tenant

    timestamps()
  end

  @cast_fields [
    :slug, :name, :system_prompt, :capabilities, :constraints,
    :tools_allowed, :escalation_rules, :context_injection_tier,
    :respond_format, :respond_schema, :is_predefined, :metadata,
    :tenant_id
  ]

  @required_fields [:slug, :name, :system_prompt]

  def changeset(role_template, attrs) do
    role_template
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:context_injection_tier, ["auto", "tier1", "tier2", "tier3"])
    |> validate_inclusion(:respond_format, ["json", "markdown"])
    |> validate_length(:slug, min: 2, max: 64)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9\-]*[a-z0-9]$/, message: "must be lowercase alphanumeric with hyphens")
    |> unique_constraint([:slug, :tenant_id], name: :role_templates_slug_tenant_unique)
    |> unique_constraint([:slug], name: :role_templates_predefined_slug_unique)
  end

  @doc "Convert role template to a map for API responses."
  def to_map(%__MODULE__{} = rt) do
    %{
      id: rt.id,
      slug: rt.slug,
      name: rt.name,
      system_prompt: rt.system_prompt,
      capabilities: rt.capabilities || [],
      constraints: rt.constraints || [],
      tools_allowed: rt.tools_allowed || [],
      escalation_rules: rt.escalation_rules,
      context_injection_tier: rt.context_injection_tier,
      respond_format: rt.respond_format,
      respond_schema: rt.respond_schema,
      is_predefined: rt.is_predefined,
      metadata: rt.metadata || %{},
      tenant_id: rt.tenant_id
    }
  end
end
