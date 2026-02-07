defmodule Hub.Providers.CredentialEncryption do
  @moduledoc """
  Encrypts and decrypts provider credentials at rest using AES-256-GCM.

  The encryption key is derived from the `PROVIDER_ENCRYPTION_KEY` env var
  or falls back to the Phoenix secret_key_base.
  """

  @aad "ringforge_provider_creds_v1"

  @doc "Encrypt a credentials map. Returns `{iv, ciphertext, tag}` as base64."
  def encrypt(credentials) when is_map(credentials) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(12)
    plaintext = Jason.encode!(credentials)

    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :aes_256_gcm, key, iv, plaintext, @aad, true
    )

    %{
      "iv" => Base.encode64(iv),
      "ciphertext" => Base.encode64(ciphertext),
      "tag" => Base.encode64(tag),
      "v" => 1
    }
  end

  @doc "Decrypt credentials. Returns the original map."
  def decrypt(%{"iv" => iv_b64, "ciphertext" => ct_b64, "tag" => tag_b64, "v" => 1}) do
    key = derive_key()
    iv = Base.decode64!(iv_b64)
    ciphertext = Base.decode64!(ct_b64)
    tag = Base.decode64!(tag_b64)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) ->
        {:ok, Jason.decode!(plaintext)}

      :error ->
        {:error, :decryption_failed}
    end
  end

  # Unencrypted credentials (legacy/dev) — pass through
  def decrypt(credentials) when is_map(credentials) do
    if Map.has_key?(credentials, "iv") do
      {:error, :invalid_encrypted_format}
    else
      {:ok, credentials}
    end
  end

  @doc "Mask sensitive fields in credentials for display."
  def mask(credentials) when is_map(credentials) do
    Map.new(credentials, fn {k, v} ->
      if sensitive_field?(k) do
        {k, mask_value(v)}
      else
        {k, v}
      end
    end)
  end

  defp sensitive_field?(key) when is_binary(key) do
    key_lower = String.downcase(key)
    String.contains?(key_lower, "token") or
    String.contains?(key_lower, "secret") or
    String.contains?(key_lower, "password") or
    String.contains?(key_lower, "key")
  end
  defp sensitive_field?(_), do: false

  defp mask_value(v) when is_binary(v) and byte_size(v) > 8 do
    String.slice(v, 0, 4) <> "••••" <> String.slice(v, -4, 4)
  end
  defp mask_value(_), do: "••••••••"

  defp derive_key do
    env_key = System.get_env("PROVIDER_ENCRYPTION_KEY")
    base = if env_key && byte_size(env_key) >= 32 do
      env_key
    else
      # Fall back to secret_key_base
      Application.get_env(:hub, Hub.Endpoint)[:secret_key_base] || :crypto.strong_rand_bytes(32) |> Base.encode64()
    end

    :crypto.hash(:sha256, base)
  end
end
