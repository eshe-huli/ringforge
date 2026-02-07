defmodule Hub.Invites do
  @moduledoc """
  Context for invite code management.

  Handles creation, validation, usage tracking, and revocation of
  invite codes. Used to gate registration when REGISTRATION_MODE=invite_only.
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Auth.InviteCode

  @code_length 8
  @code_alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  @doc """
  Creates a new invite code for the given tenant.

  Options:
  - `:max_uses` — maximum number of times the code can be used (default: 1)
  - `:expires_at` — optional UTC datetime after which the code is invalid
  """
  def create_invite(tenant_id, opts \\ []) do
    code = generate_code()
    max_uses = Keyword.get(opts, :max_uses, 1)
    expires_at = Keyword.get(opts, :expires_at)

    attrs = %{
      code: code,
      max_uses: max_uses,
      created_by: tenant_id,
      expires_at: expires_at
    }

    case %InviteCode{} |> InviteCode.changeset(attrs) |> Repo.insert() do
      {:ok, invite} ->
        Hub.Audit.log("invite.created", {"tenant", tenant_id}, {"invite", invite.code}, %{
          tenant_id: tenant_id,
          max_uses: max_uses
        })

        {:ok, invite}

      error ->
        error
    end
  end

  @doc """
  Validates and uses an invite code.

  Returns `{:ok, invite}` if the code is valid and has uses remaining,
  atomically incrementing the usage count. Returns `{:error, reason}` otherwise.
  """
  def use_invite(code) when is_binary(code) do
    now = DateTime.utc_now()

    query =
      from i in InviteCode,
        where: i.code == ^code,
        where: i.uses < i.max_uses,
        where: is_nil(i.expires_at) or i.expires_at > ^now

    case Repo.one(query) do
      nil ->
        {:error, :invalid_invite_code}

      %InviteCode{} = invite ->
        {count, _} =
          from(i in InviteCode,
            where: i.id == ^invite.id and i.uses < i.max_uses
          )
          |> Repo.update_all(inc: [uses: 1])

        if count > 0 do
          used_invite = Repo.get!(InviteCode, invite.id)

          Hub.Audit.log("invite.used", {"system", "system"}, {"invite", invite.code}, %{
            tenant_id: invite.created_by
          })

          {:ok, used_invite}
        else
          {:error, :invite_code_exhausted}
        end
    end
  end

  def use_invite(_), do: {:error, :invalid_invite_code}

  @doc "Lists all invite codes created by a tenant."
  def list_invites(tenant_id) do
    from(i in InviteCode,
      where: i.created_by == ^tenant_id,
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Revokes (deletes) an invite code, ensuring it belongs to the given tenant."
  def revoke_invite(code, tenant_id) do
    case Repo.one(from i in InviteCode, where: i.code == ^code and i.created_by == ^tenant_id) do
      nil -> {:error, :not_found}
      invite -> Repo.delete(invite)
    end
  end

  @doc "Returns the current registration mode (:open or :invite_only)."
  def registration_mode do
    mode =
      Application.get_env(:hub, Hub.Auth, [])
      |> Keyword.get(:registration_mode, "invite_only")

    case mode do
      "open" -> :open
      _ -> :invite_only
    end
  end

  @doc "Returns true if registration requires an invite code."
  def invite_only?, do: registration_mode() == :invite_only

  # --- Helpers ---

  defp generate_code do
    for _ <- 1..@code_length, into: "" do
      <<Enum.random(@code_alphabet)>>
    end
  end
end
