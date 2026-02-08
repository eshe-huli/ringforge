defmodule Hub.Messaging.Crypto do
  @moduledoc """
  Message-level encryption and signing for Ringforge messaging.

  Uses a shared secret derived from the fleet's API key to provide:
  - **Signing (JWS-like)**: HMAC-SHA256 — integrity + authenticity
  - **Encryption (JWE-like)**: AES-256-GCM — confidentiality + integrity

  ## Architecture

  Every fleet has a unique shared secret derived from its live API key.
  When an agent connects with an API key, both sides (Hub + SDK) can derive
  the same encryption key. Messages between agents are encrypted at rest
  and in transit through PubSub/StorePort.

  ## Wire Protocol

  Agents can opt-in to encryption per-message:
  - `message:send` with `"encrypted": true` → body is JWE-encrypted
  - `message:send` with `"signed": true` → body includes HMAC signature
  - Both can be combined

  ## Key Derivation

  ```
  fleet_secret = HMAC-SHA256(api_key, "ringforge:fleet:" <> fleet_id)
  signing_key  = HMAC-SHA256(fleet_secret, "ringforge:sign")
  encryption_key = HMAC-SHA256(fleet_secret, "ringforge:encrypt")
  ```

  This gives us 32-byte keys for both signing and encryption.
  """

  require Logger

  # ── Key Derivation ──────────────────────────────────────────

  @doc """
  Derive the fleet-level shared secret from an API key and fleet ID.
  Both Hub and SDK use the same derivation, so they agree on keys.
  """
  @spec derive_fleet_secret(String.t(), String.t()) :: binary()
  def derive_fleet_secret(api_key, fleet_id) do
    :crypto.mac(:hmac, :sha256, api_key, "ringforge:fleet:" <> fleet_id)
  end

  @doc "Derive the signing key from a fleet secret."
  @spec signing_key(binary()) :: binary()
  def signing_key(fleet_secret) do
    :crypto.mac(:hmac, :sha256, fleet_secret, "ringforge:sign")
  end

  @doc "Derive the encryption key from a fleet secret."
  @spec encryption_key(binary()) :: binary()
  def encryption_key(fleet_secret) do
    :crypto.mac(:hmac, :sha256, fleet_secret, "ringforge:encrypt")
  end

  @doc """
  Derive all keys for a fleet from its API key.
  Returns `{signing_key, encryption_key}` — both 32-byte binaries.
  """
  @spec derive_keys(String.t(), String.t()) :: {binary(), binary()}
  def derive_keys(api_key, fleet_id) do
    secret = derive_fleet_secret(api_key, fleet_id)
    {signing_key(secret), encryption_key(secret)}
  end

  # ── Signing (JWS-like: HMAC-SHA256) ────────────────────────

  @doc """
  Sign a message body. Returns `{body, signature}`.
  The signature is Base64url-encoded HMAC-SHA256.
  """
  @spec sign(String.t() | map(), binary()) :: {String.t(), String.t()}
  def sign(body, sign_key) when is_map(body) do
    sign(Jason.encode!(body), sign_key)
  end

  def sign(body, sign_key) when is_binary(body) do
    signature =
      :crypto.mac(:hmac, :sha256, sign_key, body)
      |> Base.url_encode64(padding: false)

    {body, signature}
  end

  @doc """
  Verify a signed message. Returns `:ok` or `{:error, :invalid_signature}`.
  """
  @spec verify(String.t(), String.t(), binary()) :: :ok | {:error, :invalid_signature}
  def verify(body, signature, sign_key) do
    expected =
      :crypto.mac(:hmac, :sha256, sign_key, body)
      |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  # ── Encryption (JWE-like: AES-256-GCM) ─────────────────────

  @doc """
  Encrypt a message body. Returns a Base64url-encoded ciphertext blob.

  Format: `iv:ciphertext:tag` (all Base64url-encoded, concatenated with colons)
  """
  @spec encrypt(String.t() | map(), binary()) :: String.t()
  def encrypt(plaintext, enc_key) when is_map(plaintext) do
    encrypt(Jason.encode!(plaintext), enc_key)
  end

  def encrypt(plaintext, enc_key) when is_binary(plaintext) do
    # 12-byte random IV for AES-256-GCM
    iv = :crypto.strong_rand_bytes(12)

    # Encrypt with AES-256-GCM
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        enc_key,
        iv,
        plaintext,
        _aad = "ringforge-msg",
        _tag_length = 16,
        true
      )

    # Encode as iv:ciphertext:tag
    [iv, ciphertext, tag]
    |> Enum.map(&Base.url_encode64(&1, padding: false))
    |> Enum.join(":")
  end

  @doc """
  Decrypt a message body. Returns `{:ok, plaintext}` or `{:error, :decryption_failed}`.
  """
  @spec decrypt(String.t(), binary()) :: {:ok, String.t()} | {:error, :decryption_failed}
  def decrypt(ciphertext_blob, enc_key) do
    with [iv_b64, ct_b64, tag_b64] <- String.split(ciphertext_blob, ":"),
         {:ok, iv} <- Base.url_decode64(iv_b64, padding: false),
         {:ok, ciphertext} <- Base.url_decode64(ct_b64, padding: false),
         {:ok, tag} <- Base.url_decode64(tag_b64, padding: false) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             enc_key,
             iv,
             ciphertext,
             _aad = "ringforge-msg",
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) ->
          {:ok, plaintext}

        :error ->
          {:error, :decryption_failed}
      end
    else
      _ -> {:error, :decryption_failed}
    end
  end

  # ── Combined Sign + Encrypt ──────────────────────────────────

  @doc """
  Sign then encrypt a message body (sign-then-encrypt).
  Returns an encrypted envelope with the signature inside.
  """
  @spec seal(map(), binary(), binary()) :: String.t()
  def seal(body, sign_key, enc_key) do
    json = Jason.encode!(body)
    {_, signature} = sign(json, sign_key)

    # Package body + signature together, then encrypt
    sealed = Jason.encode!(%{"body" => json, "sig" => signature})
    encrypt(sealed, enc_key)
  end

  @doc """
  Decrypt then verify a sealed message (decrypt-then-verify).
  Returns `{:ok, body_map}` or `{:error, reason}`.
  """
  @spec unseal(String.t(), binary(), binary()) :: {:ok, map()} | {:error, atom()}
  def unseal(sealed_blob, sign_key, enc_key) do
    with {:ok, decrypted} <- decrypt(sealed_blob, enc_key),
         {:ok, %{"body" => body_json, "sig" => signature}} <- Jason.decode(decrypted),
         :ok <- verify(body_json, signature, sign_key),
         {:ok, body} <- Jason.decode(body_json) do
      {:ok, body}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unseal_failed}
    end
  end

  # ── Fleet Key Cache ──────────────────────────────────────────

  @doc """
  Get or derive encryption keys for a fleet.
  Caches in process dictionary for performance.
  """
  @spec fleet_keys(String.t()) :: {binary(), binary()} | nil
  def fleet_keys(fleet_id) do
    cache_key = {:ringforge_keys, fleet_id}

    case Process.get(cache_key) do
      nil ->
        case resolve_fleet_api_key(fleet_id) do
          nil -> nil
          api_key ->
            keys = derive_keys(api_key, fleet_id)
            Process.put(cache_key, keys)
            keys
        end

      keys ->
        keys
    end
  end

  defp resolve_fleet_api_key(fleet_id) do
    # Look up the fleet's active API key from DB
    import Ecto.Query

    query =
      from(k in Hub.Schemas.ApiKey,
        join: f in Hub.Schemas.Fleet, on: k.fleet_id == f.id,
        where: f.id == ^fleet_id and k.revoked == false,
        order_by: [desc: k.inserted_at],
        limit: 1,
        select: k.key
      )

    case Hub.Repo.one(query) do
      nil -> nil
      key -> key
    end
  rescue
    _ -> nil
  end

  # ── Wire Protocol Helpers ────────────────────────────────────

  @doc """
  Process an incoming message that may be encrypted/signed.
  Returns the decrypted/verified body or the original body if not encrypted.
  """
  @spec process_incoming(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def process_incoming(%{"sealed" => sealed_blob}, fleet_id) do
    case fleet_keys(fleet_id) do
      {sign_key, enc_key} -> unseal(sealed_blob, sign_key, enc_key)
      nil -> {:error, :no_fleet_keys}
    end
  end

  def process_incoming(%{"encrypted" => ciphertext, "signature" => sig}, fleet_id) do
    case fleet_keys(fleet_id) do
      {sign_key, enc_key} ->
        with {:ok, plaintext} <- decrypt(ciphertext, enc_key),
             :ok <- verify(plaintext, sig, sign_key),
             {:ok, body} <- Jason.decode(plaintext) do
          {:ok, body}
        end

      nil ->
        {:error, :no_fleet_keys}
    end
  end

  def process_incoming(%{"encrypted" => ciphertext}, fleet_id) do
    case fleet_keys(fleet_id) do
      {_sign_key, enc_key} ->
        case decrypt(ciphertext, enc_key) do
          {:ok, plaintext} -> Jason.decode(plaintext)
          error -> error
        end

      nil ->
        {:error, :no_fleet_keys}
    end
  end

  # Not encrypted — pass through
  def process_incoming(body, _fleet_id) when is_map(body), do: {:ok, body}

  @doc """
  Wrap an outgoing message with encryption if the fleet supports it.
  """
  @spec wrap_outgoing(map(), String.t(), keyword()) :: map()
  def wrap_outgoing(body, fleet_id, opts \\ []) do
    encrypt? = Keyword.get(opts, :encrypt, false)
    sign? = Keyword.get(opts, :sign, false)

    cond do
      encrypt? and sign? ->
        case fleet_keys(fleet_id) do
          {sign_key, enc_key} ->
            %{"sealed" => seal(body, sign_key, enc_key)}

          nil ->
            body
        end

      encrypt? ->
        case fleet_keys(fleet_id) do
          {_sign_key, enc_key} ->
            %{"encrypted" => encrypt(body, enc_key)}

          nil ->
            body
        end

      sign? ->
        case fleet_keys(fleet_id) do
          {sign_key, _enc_key} ->
            json = Jason.encode!(body)
            {_, signature} = sign(json, sign_key)
            Map.put(body, "_signature", signature)

          nil ->
            body
        end

      true ->
        body
    end
  end
end
