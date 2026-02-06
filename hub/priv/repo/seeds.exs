# Seeds for Ringforge hub
#
# Run with: mix run priv/repo/seeds.exs

alias Hub.Repo
alias Hub.Auth.{Tenant, Fleet}

# Create default tenant
{:ok, tenant} =
  %Tenant{}
  |> Tenant.changeset(%{name: "ben", plan: "free"})
  |> Repo.insert()

IO.puts("Created tenant: #{tenant.name} (#{tenant.id})")

# Create default fleet
{:ok, fleet} =
  %Fleet{}
  |> Fleet.changeset(%{name: "default", tenant_id: tenant.id})
  |> Repo.insert()

IO.puts("Created fleet: #{fleet.name} (#{fleet.id})")

# Generate a live API key
{:ok, raw_key, api_key} = Hub.Auth.generate_api_key("live", tenant.id, fleet.id)

IO.puts("")
IO.puts("========================================")
IO.puts("  API Key (save this — shown only once)")
IO.puts("========================================")
IO.puts("  #{raw_key}")
IO.puts("========================================")
IO.puts("")
IO.puts("Key ID: #{api_key.id}")
IO.puts("Prefix: #{api_key.key_prefix}")
IO.puts("Type:   #{api_key.type}")
