defmodule Hub.S3 do
  @moduledoc """
  S3 client for Garage-backed file storage.

  Handles presigned URL generation (PUT for uploads, GET for downloads)
  and object lifecycle. Configured via `config :hub, Hub.S3`.
  """

  require Logger

  @presign_ttl 3600  # 1 hour

  # ── Public API ─────────────────────────────────────────────

  @doc """
  Generate a presigned PUT URL for uploading a file.

  Returns `{:ok, url, expires_at}` where `url` is the presigned PUT URL
  and `expires_at` is the ISO 8601 expiry timestamp.
  """
  @spec presigned_put(String.t(), String.t(), integer()) :: {:ok, String.t(), String.t()}
  def presigned_put(s3_key, content_type, _size) do
    config = config()
    bucket = config[:bucket]

    opts = [
      expires_in: @presign_ttl,
      virtual_host: false,
      query_params: [{"Content-Type", content_type}]
    ]

    {:ok, url} =
      ExAws.S3.presigned_url(
        ex_aws_config(),
        :put,
        bucket,
        s3_key,
        opts
      )

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@presign_ttl, :second)
      |> DateTime.to_iso8601()

    {:ok, url, expires_at}
  end

  @doc """
  Generate a presigned GET URL for downloading a file.

  Returns `{:ok, url, expires_at}`.
  """
  @spec presigned_get(String.t()) :: {:ok, String.t(), String.t()}
  def presigned_get(s3_key) do
    config = config()
    bucket = config[:bucket]

    opts = [
      expires_in: @presign_ttl,
      virtual_host: false
    ]

    {:ok, url} =
      ExAws.S3.presigned_url(
        ex_aws_config(),
        :get,
        bucket,
        s3_key,
        opts
      )

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@presign_ttl, :second)
      |> DateTime.to_iso8601()

    {:ok, url, expires_at}
  end

  @doc """
  Delete an object from S3.
  """
  @spec delete_object(String.t()) :: :ok | {:error, term()}
  def delete_object(s3_key) do
    config = config()
    bucket = config[:bucket]

    case ExAws.S3.delete_object(bucket, s3_key) |> ExAws.request(ex_aws_overrides()) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.error("[Hub.S3] Failed to delete #{s3_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Check if an object exists in S3 (HEAD request).
  """
  @spec head_object(String.t()) :: {:ok, map()} | {:error, term()}
  def head_object(s3_key) do
    config = config()
    bucket = config[:bucket]

    case ExAws.S3.head_object(bucket, s3_key) |> ExAws.request(ex_aws_overrides()) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp config do
    Application.get_env(:hub, Hub.S3, [])
  end

  # Build ExAws config for presigned URL generation and requests.
  # Returns a keyword list that works with both ExAws.Config.new/2
  # and ExAws.request/2.
  defp ex_aws_overrides do
    config = config()
    endpoint_uri = URI.parse(config[:endpoint] || "http://localhost:3900")

    [
      access_key_id: config[:access_key],
      secret_access_key: config[:secret_key],
      region: config[:region] || "keyring",
      scheme: "#{endpoint_uri.scheme}://",
      host: endpoint_uri.host,
      port: endpoint_uri.port
    ]
  end

  defp ex_aws_config do
    ExAws.Config.new(:s3, ex_aws_overrides())
  end
end
