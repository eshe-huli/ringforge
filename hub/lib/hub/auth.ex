defmodule Hub.Auth do
  @moduledoc """
  Authentication and identity context for Ringforge.

  Handles API key generation/validation, agent registration,
  and Ed25519 challenge-response authentication.
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Auth.{Fleet, ApiKey, Agent}

  @base62_alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # --- API Key Management ---

  @doc """
  Generates a new API key of the given type ("live", "test", or "admin").

  Returns `{:ok, raw_key, %ApiKey{}}` where `raw_key` is the plaintext key
  in the format `rf_{type}_{base62(32)}`. The raw key is only available at
  creation time — only the SHA-256 hash is persisted.
  """
  def generate_api_key(type, tenant_id, fleet_id \\ nil) when type in ["live", "test", "admin"] do
    raw_token = base62_random(32)
    raw_key = "rf_#{type}_#{raw_token}"
    key_hash = hash_key(raw_key)
    key_prefix = String.slice(raw_key, 0, 8)

    attrs = %{
      key_hash: key_hash,
      key_prefix: key_prefix,
      type: type,
      tenant_id: tenant_id,
      fleet_id: fleet_id
    }

    case %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
      {:ok, api_key} -> {:ok, raw_key, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Validates a raw API key by computing its SHA-256 hash and looking it up.

  Returns `{:ok, %ApiKey{}}` with preloaded tenant and fleet, or `{:error, :invalid}`.
  Expired and revoked keys are rejected.
  """
  def validate_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)

    query =
      from k in ApiKey,
        where: k.key_hash == ^key_hash,
        where: is_nil(k.revoked_at),
        preload: [:tenant, :fleet]

    case Repo.one(query) do
      nil ->
        {:error, :invalid}

      %ApiKey{expires_at: expires_at} = key ->
        if is_nil(expires_at) or DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, key}
        else
          {:error, :invalid}
        end
    end
  end

  def validate_api_key(_), do: {:error, :invalid}

  # --- Agent Registration ---

  @doc """
  Registers or reconnects an agent using a validated API key.

  If the agent provides a name + fleet combo that already exists, we reconnect
  and update metadata instead of creating a duplicate. Otherwise a new agent is
  created with a unique `agent_id` in the format "ag_{random}".
  """
  def register_agent(%ApiKey{} = api_key, agent_params) do
    fleet_id = api_key.fleet_id || default_fleet_id(api_key.tenant_id)
    name = Map.get(agent_params, :name)
    agent_id = "ag_#{base62_random(12)}"

    attrs =
      Map.merge(agent_params, %{
        agent_id: agent_id,
        tenant_id: api_key.tenant_id,
        fleet_id: fleet_id,
        registered_via_key_id: api_key.id,
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    if name && name != "" do
      # Named agent: find existing or insert new, atomic
      case Repo.one(from a in Agent, where: a.name == ^name and a.fleet_id == ^fleet_id, limit: 1) do
        %Agent{} = existing ->
          update_attrs = %{
            framework: Map.get(agent_params, :framework) || existing.framework,
            capabilities: Map.get(agent_params, :capabilities) || existing.capabilities,
            last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }

          # Bind or update public key if provided
          update_attrs =
            case Map.get(agent_params, :public_key) do
              pk when is_binary(pk) and byte_size(pk) == 32 -> Map.put(update_attrs, :public_key, pk)
              _ -> update_attrs
            end

          existing
          |> Agent.changeset(update_attrs)
          |> Repo.update()

        nil ->
          case %Agent{} |> Agent.changeset(attrs) |> Repo.insert() do
            {:ok, agent} ->
              {:ok, agent}

            {:error, %Ecto.Changeset{errors: _}} ->
              # Race condition: another connection inserted first. Retry find.
              case Repo.one(from a in Agent, where: a.name == ^name and a.fleet_id == ^fleet_id, limit: 1) do
                %Agent{} = agent -> {:ok, agent}
                nil -> {:error, :registration_failed}
              end
          end
      end
    else
      # Unnamed agent: always create new
      %Agent{} |> Agent.changeset(attrs) |> Repo.insert()
    end
  end

  # --- Challenge-Response Auth ---

  @doc """
  Generates a random 32-byte challenge, returned as base64.
  """
  def generate_challenge do
    :crypto.strong_rand_bytes(32) |> Base.encode64()
  end

  @doc """
  Verifies an Ed25519 signature of a challenge against an agent's public key.

  Returns `:ok` on success, `{:error, :invalid_signature}` on failure.
  """
  def verify_challenge(%Agent{public_key: public_key}, challenge, signature)
      when is_binary(public_key) and byte_size(public_key) == 32 do
    challenge_bytes = Base.decode64!(challenge)
    signature_bytes = Base.decode64!(signature)

    if :crypto.verify(:eddsa, :none, challenge_bytes, signature_bytes, [public_key, :ed25519]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  def verify_challenge(_, _, _), do: {:error, :no_public_key}

  # --- Key Rotation ---

  @doc """
  Updates an agent's Ed25519 public key. Used for key rotation during
  an authenticated session. The old key is immediately invalidated.

  Accepts raw 32-byte binary public key.
  """
  def update_public_key(%Agent{} = agent, public_key_bytes)
      when is_binary(public_key_bytes) and byte_size(public_key_bytes) == 32 do
    # Revoke any pending challenges for this agent (old key can't sign them)
    Hub.ChallengeStore.revoke(agent.agent_id)

    agent
    |> Agent.changeset(%{public_key: public_key_bytes})
    |> Repo.update()
  end

  def update_public_key(_, _), do: {:error, :invalid_public_key}

  # --- Lookups ---

  @doc """
  Finds an agent by its string agent_id (e.g. "ag_abc123").
  """
  def find_agent(agent_id) when is_binary(agent_id) do
    case Repo.get_by(Agent, agent_id: agent_id) do
      nil -> {:error, :not_found}
      agent -> {:ok, Repo.preload(agent, [:tenant, :fleet])}
    end
  end

  @doc """
  Updates the agent's last_seen_at timestamp.
  """
  def touch_agent(%Agent{} = agent) do
    agent
    |> Agent.changeset(%{last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  # --- Helpers ---

  defp hash_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end

  defp base62_random(length) do
    for _ <- 1..length, into: "" do
      <<Enum.random(@base62_alphabet)>>
    end
  end

  defp default_fleet_id(tenant_id) do
    query = from f in Fleet, where: f.tenant_id == ^tenant_id and f.name == "default", select: f.id
    Repo.one(query)
  end
end
