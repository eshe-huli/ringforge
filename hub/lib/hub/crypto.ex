defmodule Hub.Crypto do
  @moduledoc """
  Ed25519 cryptographic operations for agent authentication.

  Uses Erlang's built-in `:crypto` module — no external dependencies.

  ## Key Format

  Ed25519 keys are 32 bytes. Over the wire they are base64-encoded.
  In the database the raw 32-byte binary is stored directly.
  """

  @challenge_bytes 32

  @doc """
  Generates a random challenge: 32 cryptographically secure random bytes,
  returned as a base64 string.
  """
  @spec generate_challenge() :: String.t()
  def generate_challenge do
    :crypto.strong_rand_bytes(@challenge_bytes) |> Base.encode64()
  end

  @doc """
  Verifies an Ed25519 signature of a challenge against a public key.

  All arguments are base64-encoded strings. Returns `true` if the
  signature is valid, `false` otherwise.

  Returns `false` (rather than raising) on any decoding or verification error.
  """
  @spec verify_signature(String.t(), String.t(), String.t()) :: boolean()
  def verify_signature(public_key_b64, challenge_b64, signature_b64) do
    with {:ok, pk} when byte_size(pk) == 32 <- Base.decode64(public_key_b64),
         {:ok, challenge} <- Base.decode64(challenge_b64),
         {:ok, sig} when byte_size(sig) == 64 <- Base.decode64(signature_b64) do
      :crypto.verify(:eddsa, :none, challenge, sig, [pk, :ed25519])
    else
      _ -> false
    end
  end

  @doc """
  Verifies an Ed25519 signature using a raw binary public key (as stored in DB)
  and base64-encoded challenge + signature.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec verify_signature_raw(binary(), String.t(), String.t()) :: :ok | {:error, atom()}
  def verify_signature_raw(public_key_bytes, challenge_b64, signature_b64)
      when is_binary(public_key_bytes) and byte_size(public_key_bytes) == 32 do
    with {:ok, challenge} <- Base.decode64(challenge_b64),
         {:ok, sig} when byte_size(sig) == 64 <- Base.decode64(signature_b64) do
      if :crypto.verify(:eddsa, :none, challenge, sig, [public_key_bytes, :ed25519]) do
        :ok
      else
        {:error, :invalid_signature}
      end
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def verify_signature_raw(_, _, _), do: {:error, :invalid_public_key}

  @doc """
  Generates an Ed25519 keypair for testing purposes.

  Returns `{public_key_bytes, private_key_bytes}` — both raw 32-byte binaries.
  """
  @spec generate_keypair() :: {binary(), binary()}
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  @doc """
  Signs a message with an Ed25519 private key.

  Takes raw binary private key and a binary message (or base64-encoded challenge).
  Returns the raw 64-byte signature.
  """
  @spec sign(binary(), binary()) :: binary()
  def sign(private_key_bytes, message) when is_binary(private_key_bytes) and is_binary(message) do
    :crypto.sign(:eddsa, :none, message, [private_key_bytes, :ed25519])
  end

  @doc """
  Convenience: signs a base64-encoded challenge and returns a base64-encoded signature.
  """
  @spec sign_challenge(binary(), String.t()) :: String.t()
  def sign_challenge(private_key_bytes, challenge_b64) do
    challenge = Base.decode64!(challenge_b64)
    signature = sign(private_key_bytes, challenge)
    Base.encode64(signature)
  end

  @doc """
  Validates that a base64 string decodes to a valid 32-byte Ed25519 public key.
  Returns `{:ok, raw_bytes}` or `{:error, :invalid_public_key}`.
  """
  @spec decode_public_key(String.t()) :: {:ok, binary()} | {:error, :invalid_public_key}
  def decode_public_key(pk_base64) when is_binary(pk_base64) do
    case Base.decode64(pk_base64) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, bytes}
      _ -> {:error, :invalid_public_key}
    end
  end

  def decode_public_key(_), do: {:error, :invalid_public_key}
end
