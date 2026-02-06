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
  Registers a new agent using a validated API key.

  The agent is bound to the key's tenant and fleet. A unique `agent_id`
  in the format "ag_{random}" is generated automatically.
  """
  def register_agent(%ApiKey{} = api_key, agent_params) do
    agent_id = "ag_#{base62_random(12)}"

    # Determine fleet: use key's fleet, or fall back to default fleet for tenant
    fleet_id = api_key.fleet_id || default_fleet_id(api_key.tenant_id)

    attrs =
      Map.merge(agent_params, %{
        agent_id: agent_id,
        tenant_id: api_key.tenant_id,
        fleet_id: fleet_id,
        registered_via_key_id: api_key.id
      })

    case %Agent{} |> Agent.changeset(attrs) |> Repo.insert() do
      {:ok, agent} -> {:ok, agent}
      {:error, changeset} -> {:error, changeset}
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
