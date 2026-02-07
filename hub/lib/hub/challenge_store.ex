defmodule Hub.ChallengeStore do
  @moduledoc """
  ETS-backed store for pending Ed25519 authentication challenges.

  Each agent can have at most one active challenge at a time (prevents replay).
  Challenges expire after a configurable TTL (default 30 seconds).
  A periodic sweep removes expired entries every 60 seconds.

  ## Storage Layout

  ETS table `:hub_challenge_store` with entries:

      {agent_id, challenge_b64, inserted_at_monotonic}

  Keyed by `agent_id` — inserting a new challenge for the same agent
  overwrites the previous one.
  """
  use GenServer
  require Logger

  @table :hub_challenge_store
  @ttl_ms 30_000
  @sweep_interval_ms 60_000

  # ── Public API ──────────────────────────────────────────────

  @doc """
  Generates and stores a challenge for the given agent.

  Returns the base64-encoded challenge string. Any previous pending
  challenge for this agent is replaced.
  """
  @spec issue(String.t()) :: String.t()
  def issue(agent_id) when is_binary(agent_id) do
    challenge = Hub.Crypto.generate_challenge()
    now = System.monotonic_time(:millisecond)
    :ets.insert(@table, {agent_id, challenge, now})
    challenge
  end

  @doc """
  Verifies and consumes a challenge for the given agent.

  Returns `:ok` if the challenge matches and hasn't expired,
  `{:error, reason}` otherwise. The challenge is deleted on success
  (one-time use).
  """
  @spec verify(String.t(), String.t()) :: :ok | {:error, atom()}
  def verify(agent_id, challenge) when is_binary(agent_id) and is_binary(challenge) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, ^challenge, inserted_at}] when now - inserted_at <= @ttl_ms ->
        :ets.delete(@table, agent_id)
        :ok

      [{^agent_id, ^challenge, _inserted_at}] ->
        :ets.delete(@table, agent_id)
        {:error, :challenge_expired}

      [{^agent_id, _other_challenge, _inserted_at}] ->
        {:error, :challenge_mismatch}

      [] ->
        {:error, :no_pending_challenge}
    end
  end

  @doc """
  Retrieves the pending challenge for an agent without consuming it.
  Returns `{:ok, challenge}` or `:none`.
  """
  @spec peek(String.t()) :: {:ok, String.t()} | :none
  def peek(agent_id) when is_binary(agent_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, challenge, inserted_at}] when now - inserted_at <= @ttl_ms ->
        {:ok, challenge}

      _ ->
        :none
    end
  end

  @doc """
  Removes any pending challenge for the agent.
  """
  @spec revoke(String.t()) :: :ok
  def revoke(agent_id) when is_binary(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  end

  # ── GenServer ───────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_expired do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @ttl_ms

    # Select all entries older than TTL and delete them
    expired =
      :ets.select(@table, [
        {{:"$1", :_, :"$3"}, [{:<, :"$3", cutoff}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table, &1))

    if length(expired) > 0 do
      Logger.debug("[ChallengeStore] Swept #{length(expired)} expired challenge(s)")
    end
  end
end
