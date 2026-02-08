defmodule Hub.RoleSeeder do
  @moduledoc """
  Seeds predefined role templates on application startup.
  Runs once after the Repo is available, then stops.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Delay to ensure Repo is fully started
    Process.send_after(self(), :seed, 3_000)
    {:ok, :pending}
  end

  @impl true
  def handle_info(:seed, _state) do
    Logger.info("[RoleSeeder] Starting predefined role seeding...")

    try do
      Hub.Roles.seed_predefined_roles()
      Logger.info("[RoleSeeder] Seeding complete")
    rescue
      e ->
        Logger.error("[RoleSeeder] Seeding failed: #{Exception.message(e)}")
        Logger.error("[RoleSeeder] Stacktrace: #{inspect(__STACKTRACE__)}")
    catch
      kind, reason ->
        Logger.error("[RoleSeeder] Seeding crashed: #{inspect(kind)} #{inspect(reason)}")
    end

    {:noreply, :done}
  end
end
