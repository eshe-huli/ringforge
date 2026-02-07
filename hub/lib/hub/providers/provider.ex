defmodule Hub.Providers.Provider do
  @moduledoc """
  Behaviour for cloud provider implementations.

  Each provider (Hetzner, DigitalOcean, Contabo, AWS) implements this
  behaviour to provide a uniform interface for server provisioning.
  """

  @type credentials :: map()
  @type region :: %{id: String.t(), name: String.t(), available: boolean()}
  @type size :: %{id: String.t(), name: String.t(), vcpus: integer(), memory_mb: integer(), disk_gb: integer(), monthly_cost_cents: integer()}
  @type server_info :: %{
    external_id: String.t(),
    ip_address: String.t() | nil,
    status: String.t(),
    name: String.t()
  }
  @type opts :: map()

  @callback list_regions(credentials()) :: {:ok, [region()]} | {:error, term()}
  @callback list_sizes(credentials()) :: {:ok, [size()]} | {:error, term()}
  @callback create_server(credentials(), opts()) :: {:ok, server_info()} | {:error, term()}
  @callback destroy_server(credentials(), String.t()) :: :ok | {:error, term()}
  @callback get_server(credentials(), String.t()) :: {:ok, server_info()} | {:error, term()}

  @doc "Returns the provider module for a given provider name string."
  def module_for("hetzner"), do: Hub.Providers.Hetzner
  def module_for("digitalocean"), do: Hub.Providers.DigitalOcean
  def module_for("contabo"), do: Hub.Providers.Contabo
  def module_for("aws"), do: Hub.Providers.AWS
  def module_for(_), do: {:error, :unknown_provider}
end
