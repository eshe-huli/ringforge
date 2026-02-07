defmodule Hub.Groups do
  @moduledoc """
  Context for group management — squads, pods, and channels.
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Groups.{Group, GroupMember}

  @base62 ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # ── Create ──────────────────────────────────────────────────

  def create_group(attrs) do
    group_id = "grp_#{base62_random(12)}"

    %Group{}
    |> Group.changeset(Map.put(attrs, :group_id, group_id))
    |> Repo.insert()
  end

  # ── Query ───────────────────────────────────────────────────

  def list_groups(fleet_id, opts \\ []) do
    status = Keyword.get(opts, :status, "active")
    type = Keyword.get(opts, :type)

    query =
      from g in Group,
        where: g.fleet_id == ^fleet_id and g.status == ^status,
        order_by: [desc: g.inserted_at],
        preload: [:members]

    query =
      if type do
        from g in query, where: g.type == ^type
      else
        query
      end

    Repo.all(query)
  end

  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, Repo.preload(group, [:members])}
    end
  end

  def get_group_by_name(name, fleet_id) do
    Repo.get_by(Group, name: name, fleet_id: fleet_id)
  end

  def groups_for_agent(agent_id, fleet_id) do
    from(g in Group,
      join: m in GroupMember,
      on: m.group_id == g.id,
      where: m.agent_id == ^agent_id and g.fleet_id == ^fleet_id and g.status == "active",
      preload: [:members]
    )
    |> Repo.all()
  end

  # ── Membership ──────────────────────────────────────────────

  def join_group(group_id, agent_id, role \\ "member") do
    with {:ok, group} <- get_group(group_id) do
      %GroupMember{}
      |> GroupMember.changeset(%{
        group_id: group.id,
        agent_id: agent_id,
        role: role,
        joined_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:group_id, :agent_id])
      |> case do
        {:ok, member} -> {:ok, member}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def leave_group(group_id, agent_id) do
    with {:ok, group} <- get_group(group_id) do
      case Repo.get_by(GroupMember, group_id: group.id, agent_id: agent_id) do
        nil -> {:error, :not_member}
        member -> Repo.delete(member)
      end
    end
  end

  def is_member?(group_id, agent_id) do
    case get_group(group_id) do
      {:ok, group} ->
        Repo.exists?(
          from m in GroupMember,
            where: m.group_id == ^group.id and m.agent_id == ^agent_id
        )

      _ ->
        false
    end
  end

  def members(group_id) do
    case get_group(group_id) do
      {:ok, group} ->
        members =
          from(m in GroupMember,
            where: m.group_id == ^group.id,
            order_by: [asc: m.joined_at]
          )
          |> Repo.all()

        {:ok, members}

      error ->
        error
    end
  end

  # ── Lifecycle ───────────────────────────────────────────────

  def dissolve_group(group_id, result \\ nil) do
    with {:ok, group} <- get_group(group_id) do
      group
      |> Group.changeset(%{
        status: "dissolved",
        dissolved_at: DateTime.utc_now() |> DateTime.truncate(:second),
        result: result
      })
      |> Repo.update()
    end
  end

  def update_group(group_id, attrs) do
    with {:ok, group} <- get_group(group_id) do
      group
      |> Group.changeset(attrs)
      |> Repo.update()
    end
  end

  # ── Capability Matching ─────────────────────────────────────

  def find_matching_groups(fleet_id, required_capabilities) when is_list(required_capabilities) do
    groups = list_groups(fleet_id, status: "active")

    Enum.filter(groups, fn group ->
      group_caps = MapSet.new(group.capabilities)
      required = MapSet.new(required_capabilities)
      MapSet.subset?(required, group_caps)
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp base62_random(length) do
    for _ <- 1..length, into: "" do
      <<Enum.random(@base62)>>
    end
  end
end
