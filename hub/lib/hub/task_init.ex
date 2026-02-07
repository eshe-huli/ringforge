defmodule Hub.TaskInit do
  @moduledoc """
  Supervisor child that initializes the Hub.Task ETS tables on startup.
  Runs as a simple GenServer that calls Hub.Task.init/0 on init.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Hub.Task.init()
    {:ok, :ok}
  end
end
