defmodule Hub.Workers.OllamaBridge do
  @moduledoc """
  Virtual agent bridge for local Ollama LLM models.

  Runs as a GenServer on the Hub, registering each configured Ollama model
  as a virtual agent in FleetPresence. When the TaskSupervisor assigns a task
  to one of these virtual agents, the bridge calls the Ollama HTTP API,
  processes the response, and returns the result through the task system.

  ## Virtual Agents

  - `ollama-qwen-coder` — Qwen 2.5 Coder 7B (code, refactor, generate, format, parse)
  - `ollama-llama-general` — Llama 3.1 8B (general, summarize, classify, extract, translate)

  These appear in the dashboard and roster like any other agent.
  """
  use GenServer

  require Logger

  @ollama_url "http://localhost:11434/api/generate"
  @ollama_timeout_ms 120_000

  @models %{
    "ollama-qwen-coder" => %{
      model: "qwen2.5-coder:7b",
      capabilities: ["code", "refactor", "generate", "format", "parse"],
      name: "Qwen Coder 7B"
    },
    "ollama-llama-general" => %{
      model: "llama3.1:8b",
      capabilities: ["general", "summarize", "classify", "extract", "translate"],
      name: "Llama 3.1 8B"
    }
  }

  # ── Public API ────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the map of model agent_ids to their config."
  def models, do: @models

  @doc "Get agent IDs for all Ollama virtual agents."
  def agent_ids, do: Map.keys(@models)

  # ── GenServer Callbacks ───────────────────────────────────

  @impl true
  def init(opts) do
    fleet_id = opts[:fleet_id] || default_fleet_id()

    state = %{
      fleet_id: fleet_id,
      busy: %{}  # %{agent_id => task_id} — tracks which models are busy
    }

    # Register virtual agents in presence after a short delay
    # (ensure FleetPresence is ready)
    Process.send_after(self(), :register_agents, 500)

    {:ok, state}
  end

  @impl true
  def handle_info(:register_agents, state) do
    fleet_id = state.fleet_id

    Enum.each(@models, fn {agent_id, config} ->
      # Track in FleetPresence directly (no WebSocket needed)
      meta = %{
        agent_id: agent_id,
        name: config.name,
        framework: "ollama",
        capabilities: config.capabilities,
        state: "online",
        task: nil,
        load: 0.0,
        metadata: %{"type" => "ollama_bridge", "model" => config.model},
        connected_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      Hub.FleetPresence.track(self(), "fleet:#{fleet_id}", agent_id, meta)

      # Subscribe to task assignment notifications for this agent
      Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{fleet_id}:agent:#{agent_id}")

      Logger.info("[OllamaBridge] Registered virtual agent: #{agent_id} (#{config.name})")
    end)

    {:noreply, state}
  end

  # Handle task assignment from TaskSupervisor
  @impl true
  def handle_info({:task_assigned, msg}, state) do
    payload = msg["payload"]
    task_id = payload["task_id"]

    case Hub.Task.get(task_id) do
      {:ok, task} ->
        agent_id = task.assigned_to
        model_config = Map.get(@models, agent_id)

        if is_nil(model_config) do
          # Task not for us — ignore
          {:noreply, state}
        else
          Logger.info("[OllamaBridge] #{agent_id} claiming task #{task_id}")

          # Mark as running
          Hub.Task.start(task_id)

          # Update presence to busy
          update_presence(state.fleet_id, agent_id, "busy", "Processing: #{task_id}")

          # Process async to not block the GenServer
          bridge_pid = self()
          Task.start(fn ->
            result = call_ollama(model_config.model, task.prompt)
            send(bridge_pid, {:ollama_result, task_id, agent_id, result})
          end)

          busy = Map.put(state.busy, agent_id, task_id)
          {:noreply, %{state | busy: busy}}
        end

      _ ->
        # Task not for us or already gone
        {:noreply, state}
    end
  end

  # Handle Ollama API result
  def handle_info({:ollama_result, task_id, agent_id, result}, state) do
    case result do
      {:ok, response} ->
        Logger.info("[OllamaBridge] #{agent_id} completed task #{task_id}")
        case Hub.Task.complete(task_id, %{"response" => response, "model" => @models[agent_id].model}) do
          {:ok, completed_task} ->
            Hub.TaskSupervisor.push_task_result(completed_task)
          {:error, reason} ->
            Logger.warning("[OllamaBridge] Failed to complete #{task_id}: #{inspect(reason)}")
        end

      {:error, error} ->
        Logger.warning("[OllamaBridge] #{agent_id} failed task #{task_id}: #{error}")
        case Hub.Task.fail(task_id, error) do
          {:ok, failed_task} ->
            Hub.TaskSupervisor.push_task_result(failed_task)
          {:error, reason} ->
            Logger.warning("[OllamaBridge] Failed to record failure #{task_id}: #{inspect(reason)}")
        end
    end

    # Update presence back to online
    update_presence(state.fleet_id, agent_id, "online", nil)

    busy = Map.delete(state.busy, agent_id)
    {:noreply, %{state | busy: busy}}
  end

  # Ignore other PubSub messages
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Ollama HTTP Client ────────────────────────────────────

  defp call_ollama(model, prompt) do
    # Ensure :inets and :ssl are started
    :inets.start()
    :ssl.start()

    body = Jason.encode!(%{
      "model" => model,
      "prompt" => prompt,
      "stream" => false
    })

    url = String.to_charlist(@ollama_url)
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(
      :post,
      {url, headers, ~c"application/json", body},
      [timeout: @ollama_timeout_ms, connect_timeout: 5_000],
      [body_format: :binary]
    ) do
      {:ok, {{_http_ver, 200, _reason}, _headers, response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"response" => response}} ->
            {:ok, response}

          {:ok, decoded} ->
            {:ok, inspect(decoded)}

          {:error, _} ->
            {:error, "Failed to parse Ollama response"}
        end

      {:ok, {{_http_ver, status, _reason}, _headers, response_body}} ->
        {:error, "Ollama returned HTTP #{status}: #{response_body}"}

      {:error, reason} ->
        {:error, "Ollama request failed: #{inspect(reason)}"}
    end
  end

  # ── Presence Updates ──────────────────────────────────────

  defp update_presence(fleet_id, agent_id, new_state, task) do
    topic = "fleet:#{fleet_id}"
    case Hub.FleetPresence.get_by_key(topic, agent_id) do
      [] ->
        # Re-register if presence was lost
        config = @models[agent_id]
        meta = %{
          agent_id: agent_id,
          name: config.name,
          framework: "ollama",
          capabilities: config.capabilities,
          state: new_state,
          task: task,
          load: if(new_state == "busy", do: 1.0, else: 0.0),
          metadata: %{"type" => "ollama_bridge", "model" => config.model},
          connected_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
        Hub.FleetPresence.track(self(), topic, agent_id, meta)

      %{metas: [current | _]} ->
        updated = %{current |
          state: new_state,
          task: task,
          load: if(new_state == "busy", do: 1.0, else: 0.0)
        }
        Hub.FleetPresence.update(self(), topic, agent_id, updated)
    end

    # Broadcast state change to fleet
    Phoenix.PubSub.broadcast(Hub.PubSub, topic, %Phoenix.Socket.Broadcast{
      topic: topic,
      event: "presence:state_changed",
      payload: %{
        "type" => "presence",
        "event" => "state_changed",
        "payload" => %{
          "agent_id" => agent_id,
          "name" => @models[agent_id].name,
          "state" => new_state,
          "task" => task,
          "load" => if(new_state == "busy", do: 1.0, else: 0.0)
        }
      }
    })
  end

  # ── Helpers ───────────────────────────────────────────────

  defp default_fleet_id do
    # Get the first fleet from the database (fleet_id is the PK :id)
    import Ecto.Query
    case Hub.Repo.one(from f in Hub.Auth.Fleet, limit: 1, select: f.id) do
      nil -> "default"
      fleet_id -> fleet_id
    end
  end
end
