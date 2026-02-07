defmodule Hub.Files do
  @moduledoc """
  File distribution context for RingForge.

  Manages file metadata in Postgres and coordinates with `Hub.S3` for
  presigned URL generation. All operations are tenant-scoped.

  ## Flow

  1. Agent requests upload URL via `file:upload_url`
  2. Hub generates presigned PUT URL + file_id, stores pending metadata
  3. Agent uploads directly to S3 using the presigned URL
  4. Agent confirms upload via `file:register`
  5. Hub verifies the upload (HEAD on S3) and broadcasts to fleet
  6. Other agents can request download URLs via `file:download_url`

  ## Quotas

  Per-tenant storage quotas are enforced before generating upload URLs.
  The quota is tracked as total bytes stored across all fleets.
  """

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Schemas.File, as: FileRecord
  alias Hub.S3

  require Logger

  # 500 MB per file max
  @max_file_size 500_000_000
  # Storage quotas per plan (bytes)
  @storage_quotas %{
    "free" => 1_073_741_824,         # 1 GB
    "pro" => 10_737_418_240,         # 10 GB
    "scale" => 107_374_182_400,      # 100 GB
    "enterprise" => :unlimited
  }

  # ── Public API ─────────────────────────────────────────────

  @doc """
  Generate a presigned upload URL and create a pending file record.

  Returns `{:ok, %{file_id, upload_url, expires_at}}` or `{:error, reason}`.
  """
  def upload_url(filename, size, content_type, agent_id, tenant_id, fleet_id) do
    cond do
      size > @max_file_size ->
        {:error, %{
          reason: "file_too_large",
          message: "Max file size is #{div(@max_file_size, 1_000_000)} MB.",
          max_bytes: @max_file_size
        }}

      size <= 0 ->
        {:error, %{reason: "invalid_size", message: "File size must be positive."}}

      true ->
        case check_storage_quota(tenant_id, size) do
          :ok ->
            s3_key = generate_s3_key(tenant_id, fleet_id, filename)

            attrs = %{
              filename: filename,
              content_type: content_type,
              size: size,
              s3_key: s3_key,
              agent_id: agent_id,
              tenant_id: tenant_id,
              fleet_id: fleet_id
            }

            case create_file_record(attrs) do
              {:ok, file} ->
                {:ok, url, expires_at} = S3.presigned_put(s3_key, content_type, size)

                Hub.Telemetry.execute([:hub, :file, :upload], %{count: 1, size: size}, %{
                  fleet_id: fleet_id,
                  tenant_id: tenant_id
                })

                {:ok, %{
                  file_id: file.id,
                  upload_url: url,
                  s3_key: s3_key,
                  expires_at: expires_at
                }}

              {:error, changeset} ->
                {:error, %{reason: "validation_failed", details: inspect(changeset.errors)}}
            end

          {:error, quota_error} ->
            {:error, quota_error}
        end
    end
  end

  @doc """
  Confirm a file upload is complete. Updates metadata with tags/description.

  Optionally verifies the file exists in S3 via HEAD request.
  """
  def register(file_id, tenant_id, metadata \\ %{}) do
    case get_file(file_id, tenant_id) do
      {:ok, file} ->
        updates =
          %{}
          |> maybe_put(:tags, Map.get(metadata, "tags"))
          |> maybe_put(:description, Map.get(metadata, "description"))

        case file |> FileRecord.changeset(updates) |> Repo.update() do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, %{reason: "update_failed", details: inspect(changeset.errors)}}
        end

      :not_found ->
        {:error, %{reason: "not_found", message: "File #{file_id} not found."}}
    end
  end

  @doc """
  Generate a presigned download URL for a file.
  """
  def download_url(file_id, tenant_id) do
    case get_file(file_id, tenant_id) do
      {:ok, file} ->
        {:ok, url, expires_at} = S3.presigned_get(file.s3_key)

        {:ok, %{
          file_id: file.id,
          filename: file.filename,
          content_type: file.content_type,
          size: file.size,
          download_url: url,
          expires_at: expires_at
        }}

      :not_found ->
        {:error, %{reason: "not_found", message: "File #{file_id} not found."}}
    end
  end

  @doc """
  List files for a fleet with optional filters.

  Options:
  - `:limit` — max results (default 50)
  - `:offset` — pagination offset
  - `:tags` — filter by tags (any match)
  - `:agent_id` — filter by uploader
  - `:content_type` — filter by content type prefix (e.g. "image/")
  """
  def list(fleet_id, tenant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from(f in FileRecord,
        where: f.fleet_id == ^fleet_id and f.tenant_id == ^tenant_id,
        order_by: [desc: f.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query = maybe_filter_tags(query, Keyword.get(opts, :tags))
    query = maybe_filter_agent(query, Keyword.get(opts, :agent_id))
    query = maybe_filter_content_type(query, Keyword.get(opts, :content_type))

    files = Repo.all(query)
    {:ok, Enum.map(files, &file_to_map/1)}
  end

  @doc """
  Delete a file — removes both the S3 object and the database record.

  Only the uploader (owner) can delete. Returns `:ok` or `{:error, reason}`.
  """
  def delete(file_id, tenant_id, requesting_agent_id) do
    case get_file(file_id, tenant_id) do
      {:ok, file} ->
        if file.agent_id == requesting_agent_id do
          # Delete from S3 first, then DB
          S3.delete_object(file.s3_key)
          Repo.delete(file)
          :ok
        else
          {:error, %{reason: "forbidden", message: "Only the file owner can delete."}}
        end

      :not_found ->
        {:error, %{reason: "not_found", message: "File #{file_id} not found."}}
    end
  end

  @doc """
  Get total storage used by a tenant (bytes).
  """
  def storage_used(tenant_id) do
    query = from(f in FileRecord,
      where: f.tenant_id == ^tenant_id,
      select: coalesce(sum(f.size), 0)
    )

    Repo.one(query) || 0
  end

  # ── Private ────────────────────────────────────────────────

  defp get_file(file_id, tenant_id) do
    case Repo.get(FileRecord, file_id) do
      nil -> :not_found
      file ->
        if file.tenant_id == tenant_id do
          {:ok, file}
        else
          :not_found
        end
    end
  end

  defp create_file_record(attrs) do
    %FileRecord{}
    |> FileRecord.changeset(attrs)
    |> Repo.insert()
  end

  defp generate_s3_key(tenant_id, fleet_id, filename) do
    uuid = Ecto.UUID.generate()
    # Sanitize filename — keep extension but use UUID for uniqueness
    ext = Path.extname(filename)
    safe_name = String.replace(Path.rootname(filename), ~r/[^a-zA-Z0-9_\-]/, "_")
    "#{tenant_id}/#{fleet_id}/#{uuid}/#{safe_name}#{ext}"
  end

  defp check_storage_quota(tenant_id, additional_bytes) do
    tenant = Repo.get(Hub.Auth.Tenant, tenant_id)
    plan = (tenant && tenant.plan) || "free"
    quota = Map.get(@storage_quotas, plan, @storage_quotas["free"])

    case quota do
      :unlimited ->
        :ok

      max_bytes ->
        current = storage_used(tenant_id)
        if current + additional_bytes <= max_bytes do
          :ok
        else
          {:error, %{
            reason: "storage_quota_exceeded",
            message: "Storage quota exceeded. Used: #{format_bytes(current)}, limit: #{format_bytes(max_bytes)}, requested: #{format_bytes(additional_bytes)}.",
            used: current,
            limit: max_bytes,
            fix: "Delete unused files or upgrade your plan."
          }}
        end
    end
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query
  defp maybe_filter_tags(query, tags) when is_list(tags) do
    from(f in query, where: fragment("? && ?", f.tags, ^tags))
  end

  defp maybe_filter_agent(query, nil), do: query
  defp maybe_filter_agent(query, agent_id) do
    from(f in query, where: f.agent_id == ^agent_id)
  end

  defp maybe_filter_content_type(query, nil), do: query
  defp maybe_filter_content_type(query, prefix) do
    from(f in query, where: ilike(f.content_type, ^"#{prefix}%"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def file_to_map(%FileRecord{} = f) do
    %{
      "file_id" => f.id,
      "filename" => f.filename,
      "content_type" => f.content_type,
      "size" => f.size,
      "agent_id" => f.agent_id,
      "tags" => f.tags || [],
      "description" => f.description,
      "inserted_at" => f.inserted_at && NaiveDateTime.to_iso8601(f.inserted_at),
      "updated_at" => f.updated_at && NaiveDateTime.to_iso8601(f.updated_at)
    }
  end
end
