defmodule Hub.Artifacts do
  @moduledoc """
  Agent artifact management — versioned file storage for task deliverables.

  Artifacts are code files, configs, docs, or any output an agent produces
  while working on a kanban task. Each artifact is versioned, stored in
  StorePort, and linked back to its task via context_refs.

  ## Lifecycle

      put_artifact → pending_review → approved | rejected
                                      ↓
                                  superseded (when new version arrives)
  """

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Schemas.{Artifact, ArtifactVersion}

  require Logger

  # ════════════════════════════════════════════════════════════
  # Create / Update
  # ════════════════════════════════════════════════════════════

  @doc """
  Create or update an artifact.

  If an artifact with the same filename + task_id already exists, a new
  version is created and the old artifact is marked superseded.

  attrs: %{task_id, filename, path, content, language, description, tags}
  content is raw binary (already decoded from base64 by caller).
  """
  def put_artifact(fleet_id, agent_id, attrs) when is_binary(fleet_id) and is_binary(agent_id) do
    filename = Map.get(attrs, "filename") || Map.get(attrs, :filename)
    task_id = Map.get(attrs, "task_id") || Map.get(attrs, :task_id)
    content = Map.get(attrs, "content") || Map.get(attrs, :content, "")
    path = Map.get(attrs, "path") || Map.get(attrs, :path)
    language = Map.get(attrs, "language") || Map.get(attrs, :language)
    description = Map.get(attrs, "description") || Map.get(attrs, :description)
    tags = Map.get(attrs, "tags") || Map.get(attrs, :tags, [])
    squad_id = Map.get(attrs, "squad_id") || Map.get(attrs, :squad_id)

    content_binary = if is_binary(content), do: content, else: ""
    content_type = detect_content_type(filename, language)
    checksum = compute_checksum(content_binary)
    size = byte_size(content_binary)

    # Look up tenant_id from fleet
    tenant_id = resolve_tenant_id(fleet_id)

    # Check if artifact with same filename + task_id already exists
    existing = find_existing(fleet_id, task_id, filename)

    case existing do
      nil ->
        create_new_artifact(fleet_id, tenant_id, agent_id, %{
          task_id: task_id,
          filename: filename,
          path: path,
          content_type: content_type,
          language: language,
          description: description,
          tags: tags,
          squad_id: squad_id,
          content: content_binary,
          checksum: checksum,
          size: size
        })

      %Artifact{} = old ->
        create_new_version(old, fleet_id, tenant_id, agent_id, %{
          content: content_binary,
          checksum: checksum,
          size: size,
          description: description,
          path: path,
          language: language,
          tags: tags
        })
    end
  end

  defp create_new_artifact(fleet_id, tenant_id, agent_id, params) do
    artifact_id = generate_artifact_id()
    version = 1
    s3_key = storage_key(artifact_id, version)

    # Store content
    case store_content(s3_key, params.content) do
      :ok ->
        artifact_attrs = %{
          artifact_id: artifact_id,
          task_id: params.task_id,
          filename: params.filename,
          path: params.path,
          content_type: params.content_type,
          language: params.language,
          version: version,
          size: params.size,
          checksum: "sha256:#{params.checksum}",
          s3_key: s3_key,
          description: params.description,
          tags: params.tags || [],
          status: "pending_review",
          created_by: agent_id,
          fleet_id: fleet_id,
          squad_id: params.squad_id,
          tenant_id: tenant_id
        }

        changeset = Artifact.changeset(%Artifact{}, artifact_attrs)

        case Repo.insert(changeset) do
          {:ok, artifact} ->
            # Create version record
            create_version_record(artifact, agent_id, fleet_id, tenant_id, nil)
            # Link to kanban task
            link_to_task(artifact)
            Logger.info("[Artifacts] Created #{artifact_id} (#{params.filename}) by #{agent_id}")
            {:ok, artifact}

          {:error, changeset} ->
            Logger.error("[Artifacts] Failed to create artifact: #{inspect(changeset.errors)}")
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, %{reason: "storage_failed", details: inspect(reason)}}
    end
  end

  defp create_new_version(old_artifact, fleet_id, tenant_id, agent_id, params) do
    new_version = old_artifact.version + 1
    new_artifact_id = old_artifact.artifact_id
    s3_key = storage_key(new_artifact_id, new_version)

    case store_content(s3_key, params.content) do
      :ok ->
        Repo.transaction(fn ->
          # Mark old as superseded
          old_artifact
          |> Ecto.Changeset.change(%{status: "superseded"})
          |> Repo.update!()

          # Create new artifact record
          new_attrs = %{
            artifact_id: new_artifact_id,
            task_id: old_artifact.task_id,
            filename: old_artifact.filename,
            path: params.path || old_artifact.path,
            content_type: old_artifact.content_type,
            language: params.language || old_artifact.language,
            version: new_version,
            size: params.size,
            checksum: "sha256:#{params.checksum}",
            s3_key: s3_key,
            description: params.description || old_artifact.description,
            tags: params.tags || old_artifact.tags,
            status: "pending_review",
            created_by: agent_id,
            fleet_id: fleet_id,
            squad_id: old_artifact.squad_id,
            tenant_id: tenant_id
          }

          case Repo.insert(Artifact.changeset(%Artifact{}, new_attrs)) do
            {:ok, artifact} ->
              create_version_record(artifact, agent_id, fleet_id, tenant_id, params.description)
              Logger.info("[Artifacts] Updated #{new_artifact_id} to v#{new_version} by #{agent_id}")
              artifact

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      {:error, reason} ->
        {:error, %{reason: "storage_failed", details: inspect(reason)}}
    end
  end

  defp create_version_record(artifact, agent_id, fleet_id, tenant_id, change_desc) do
    version_attrs = %{
      artifact_id: artifact.artifact_id,
      version: artifact.version,
      s3_key: artifact.s3_key,
      size: artifact.size,
      checksum: artifact.checksum,
      created_by: agent_id,
      change_description: change_desc,
      fleet_id: fleet_id,
      tenant_id: tenant_id
    }

    %ArtifactVersion{}
    |> ArtifactVersion.changeset(version_attrs)
    |> Repo.insert()
  end

  # ════════════════════════════════════════════════════════════
  # Read
  # ════════════════════════════════════════════════════════════

  @doc "Get the latest (non-superseded) artifact by artifact_id."
  def get_artifact(artifact_id) when is_binary(artifact_id) do
    query =
      from a in Artifact,
        where: a.artifact_id == ^artifact_id and a.status != "superseded",
        order_by: [desc: a.version],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  @doc "Get a specific version record."
  def get_artifact_version(artifact_id, version) do
    query =
      from v in ArtifactVersion,
        where: v.artifact_id == ^artifact_id and v.version == ^version

    case Repo.one(query) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc "Download artifact content from storage."
  def get_artifact_content(artifact_id) when is_binary(artifact_id) do
    case get_artifact(artifact_id) do
      {:ok, artifact} -> fetch_content(artifact.s3_key)
      error -> error
    end
  end

  @doc "Download a specific version's content."
  def get_version_content(artifact_id, version) do
    s3_key = storage_key(artifact_id, version)
    fetch_content(s3_key)
  end

  # ════════════════════════════════════════════════════════════
  # List / Search
  # ════════════════════════════════════════════════════════════

  @doc """
  List artifacts for a fleet with optional filters.

  opts: task_id, status, created_by, language, tags, limit
  """
  def list_artifacts(fleet_id, opts \\ %{}) do
    limit = Map.get(opts, "limit", Map.get(opts, :limit, 100))

    query =
      from a in Artifact,
        where: a.fleet_id == ^fleet_id,
        order_by: [desc: a.inserted_at],
        limit: ^limit

    query = maybe_filter(query, :task_id, Map.get(opts, "task_id", Map.get(opts, :task_id)))
    query = maybe_filter(query, :status, Map.get(opts, "status", Map.get(opts, :status)))
    query = maybe_filter(query, :created_by, Map.get(opts, "created_by", Map.get(opts, :created_by)))
    query = maybe_filter(query, :language, Map.get(opts, "language", Map.get(opts, :language)))

    query =
      case Map.get(opts, "tags", Map.get(opts, :tags)) do
        nil -> query
        tags when is_list(tags) -> from a in query, where: fragment("? && ?", a.tags, ^tags)
        _ -> query
      end

    # Exclude superseded by default unless status filter is explicitly set
    query =
      if Map.has_key?(opts, "status") or Map.has_key?(opts, :status) do
        query
      else
        from a in query, where: a.status != "superseded"
      end

    Repo.all(query)
  end

  @doc "Get all non-superseded artifacts for a task."
  def task_artifacts(task_id) when is_binary(task_id) do
    from(a in Artifact,
      where: a.task_id == ^task_id and a.status != "superseded",
      order_by: [asc: a.filename, desc: a.version]
    )
    |> Repo.all()
  end

  @doc "Search artifacts by filename, tags, or description."
  def search_artifacts(fleet_id, query_str) when is_binary(query_str) do
    pattern = "%#{String.replace(query_str, "%", "\\%")}%"

    from(a in Artifact,
      where:
        a.fleet_id == ^fleet_id and
          a.status != "superseded" and
          (ilike(a.filename, ^pattern) or
             ilike(a.description, ^pattern) or
             fragment("? @> ARRAY[?]::varchar[]", a.tags, ^query_str)),
      order_by: [desc: a.inserted_at],
      limit: 50
    )
    |> Repo.all()
  end

  # ════════════════════════════════════════════════════════════
  # Diff / History
  # ════════════════════════════════════════════════════════════

  @doc "Compute a unified-style diff between two versions of an artifact."
  def diff_versions(artifact_id, v1, v2) do
    with {:ok, content1} <- get_version_content(artifact_id, v1),
         {:ok, content2} <- get_version_content(artifact_id, v2) do
      lines1 = String.split(content1, "\n")
      lines2 = String.split(content2, "\n")
      diff = List.myers_difference(lines1, lines2)
      {:ok, format_diff(diff)}
    end
  end

  @doc "Get full version history for an artifact."
  def artifact_history(artifact_id) when is_binary(artifact_id) do
    from(v in ArtifactVersion,
      where: v.artifact_id == ^artifact_id,
      order_by: [asc: v.version]
    )
    |> Repo.all()
  end

  # ════════════════════════════════════════════════════════════
  # Review
  # ════════════════════════════════════════════════════════════

  @doc """
  Review an artifact (approve or reject).

  If all task artifacts are approved, optionally moves the task to "done".
  """
  def review_artifact(artifact_id, reviewer_agent_id, attrs) do
    status = Map.get(attrs, "status") || Map.get(attrs, :status)
    notes = Map.get(attrs, "notes") || Map.get(attrs, :notes)

    with {:ok, artifact} <- get_artifact(artifact_id) do
      review_attrs = %{
        status: status,
        reviewed_by: reviewer_agent_id,
        review_notes: notes,
        reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      case artifact |> Artifact.review_changeset(review_attrs) |> Repo.update() do
        {:ok, updated} ->
          Logger.info("[Artifacts] #{artifact_id} reviewed as #{status} by #{reviewer_agent_id}")

          # Check if all task artifacts are approved → auto-move task
          if status == "approved" and updated.task_id do
            maybe_complete_task(updated.task_id)
          end

          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # ════════════════════════════════════════════════════════════
  # Delete
  # ════════════════════════════════════════════════════════════

  @doc "Soft-delete: mark artifact as superseded (content stays in storage)."
  def delete_artifact(artifact_id) do
    case get_artifact(artifact_id) do
      {:ok, artifact} ->
        artifact
        |> Ecto.Changeset.change(%{status: "superseded"})
        |> Repo.update()

      error ->
        error
    end
  end

  # ════════════════════════════════════════════════════════════
  # Wire format
  # ════════════════════════════════════════════════════════════

  @doc "Convert artifact to a JSON-friendly map."
  def to_wire(artifact) do
    %{
      "artifact_id" => artifact.artifact_id,
      "task_id" => artifact.task_id,
      "filename" => artifact.filename,
      "path" => artifact.path,
      "content_type" => artifact.content_type,
      "language" => artifact.language,
      "version" => artifact.version,
      "size" => artifact.size,
      "checksum" => artifact.checksum,
      "description" => artifact.description,
      "status" => artifact.status,
      "reviewed_by" => artifact.reviewed_by,
      "review_notes" => artifact.review_notes,
      "reviewed_at" => artifact.reviewed_at && DateTime.to_iso8601(artifact.reviewed_at),
      "tags" => artifact.tags,
      "metadata" => artifact.metadata,
      "created_by" => artifact.created_by,
      "created_at" => DateTime.to_iso8601(artifact.inserted_at)
    }
  end

  @doc "Convert version record to wire format."
  def version_to_wire(version) do
    %{
      "artifact_id" => version.artifact_id,
      "version" => version.version,
      "size" => version.size,
      "checksum" => version.checksum,
      "created_by" => version.created_by,
      "change_description" => version.change_description,
      "created_at" => DateTime.to_iso8601(version.inserted_at)
    }
  end

  # ════════════════════════════════════════════════════════════
  # Private Helpers
  # ════════════════════════════════════════════════════════════

  defp generate_artifact_id do
    rand = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
    "art_#{rand}"
  end

  defp storage_key(artifact_id, version) do
    "art_content:#{artifact_id}:v#{version}"
  end

  defp store_content(key, content) do
    case Hub.StorePort.put_document(key, content, <<>>) do
      {:ok, _} -> :ok
      :ok -> :ok
      error -> error
    end
  end

  defp fetch_content(key) do
    case Hub.StorePort.get_document(key) do
      {:ok, %{meta: content}} when is_binary(content) and byte_size(content) > 0 ->
        {:ok, content}

      {:ok, {content, _crdt}} when is_binary(content) ->
        {:ok, content}

      {:ok, content} when is_binary(content) ->
        {:ok, content}

      :not_found ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compute_checksum(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp detect_content_type(filename, language) do
    cond do
      language in ~w(elixir) -> "text/x-elixir"
      language in ~w(python) -> "text/x-python"
      language in ~w(javascript js) -> "application/javascript"
      language in ~w(typescript ts) -> "application/typescript"
      language in ~w(rust) -> "text/x-rust"
      language in ~w(go) -> "text/x-go"
      language in ~w(ruby) -> "text/x-ruby"
      language in ~w(markdown md) -> "text/markdown"
      language in ~w(json) -> "application/json"
      language in ~w(yaml yml) -> "text/yaml"
      language in ~w(html) -> "text/html"
      language in ~w(css) -> "text/css"
      language in ~w(sql) -> "application/sql"
      is_binary(filename) -> detect_from_extension(filename)
      true -> "application/octet-stream"
    end
  end

  defp detect_from_extension(filename) do
    case Path.extname(filename) do
      ".ex" -> "text/x-elixir"
      ".exs" -> "text/x-elixir"
      ".py" -> "text/x-python"
      ".js" -> "application/javascript"
      ".ts" -> "application/typescript"
      ".rs" -> "text/x-rust"
      ".go" -> "text/x-go"
      ".rb" -> "text/x-ruby"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".yaml" -> "text/yaml"
      ".yml" -> "text/yaml"
      ".html" -> "text/html"
      ".css" -> "text/css"
      ".sql" -> "application/sql"
      ".txt" -> "text/plain"
      ".xml" -> "application/xml"
      ".sh" -> "text/x-shellscript"
      _ -> "application/octet-stream"
    end
  end

  defp find_existing(_fleet_id, nil, _filename), do: nil

  defp find_existing(fleet_id, task_id, filename) do
    from(a in Artifact,
      where:
        a.fleet_id == ^fleet_id and
          a.task_id == ^task_id and
          a.filename == ^filename and
          a.status != "superseded",
      order_by: [desc: a.version],
      limit: 1
    )
    |> Repo.one()
  end

  defp resolve_tenant_id(fleet_id) do
    case Repo.one(from f in Hub.Auth.Fleet, where: f.id == ^fleet_id, select: f.tenant_id) do
      nil -> fleet_id  # fallback
      tenant_id -> tenant_id
    end
  end

  defp link_to_task(%Artifact{task_id: nil}), do: :ok

  defp link_to_task(%Artifact{task_id: task_id, artifact_id: artifact_id}) do
    ref = "artifact:#{artifact_id}"

    case Hub.Kanban.get_task(task_id) do
      {:ok, task} ->
        new_refs = Enum.uniq([ref | task.context_refs || []])
        Hub.Kanban.update_task(task_id, %{context_refs: new_refs})

      _ ->
        :ok
    end
  end

  defp maybe_complete_task(task_id) do
    artifacts = task_artifacts(task_id)

    if Enum.all?(artifacts, &(&1.status == "approved")) and length(artifacts) > 0 do
      case Hub.Kanban.get_task(task_id) do
        {:ok, task} when task.lane == "review" ->
          Hub.Kanban.update_task(task_id, %{lane: "done", completed_at: DateTime.utc_now()})

        _ ->
          :ok
      end
    end
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, :task_id, val), do: from(a in query, where: a.task_id == ^val)
  defp maybe_filter(query, :status, val), do: from(a in query, where: a.status == ^val)
  defp maybe_filter(query, :created_by, val), do: from(a in query, where: a.created_by == ^val)
  defp maybe_filter(query, :language, val), do: from(a in query, where: a.language == ^val)

  defp format_diff(diff_ops) do
    diff_ops
    |> Enum.flat_map(fn
      {:eq, lines} ->
        Enum.map(lines, &("  #{&1}"))

      {:del, lines} ->
        Enum.map(lines, &("- #{&1}"))

      {:ins, lines} ->
        Enum.map(lines, &("+ #{&1}"))
    end)
    |> Enum.join("\n")
  end
end
