defmodule Hub.StoreProtocol do
  @moduledoc """
  Encodes/decodes the bincode wire protocol for the Rust storage engine.

  Wire format: 4-byte big-endian length prefix + bincode payload.
  Each payload is a tuple: (ref_id: u64-LE, Request|Response).

  Bincode 1 conventions:
    - Integers are little-endian, fixed-width
    - Enum variant index: u32 LE
    - Vec<u8>/String: u64 LE length prefix, then raw bytes
    - bool: single byte (0 or 1)
    - Tuples/structs: fields concatenated in order
  """

  # ── Request variant indices (match Rust enum order) ──────────────────

  @put_blob 0
  @get_blob 1
  @has_blob 2
  @put_document 3
  @get_document 4
  @delete_document 5
  @list_documents 6
  # @get_roots 7
  # @get_changes 8
  # @apply_changes 9

  # ── Response variant indices ─────────────────────────────────────────

  @resp_ok 0
  @resp_blob 1
  @resp_blob_stored 2
  @resp_blob_exists 3
  @resp_document 4
  @resp_document_list 5
  @resp_not_found 6
  # @resp_roots 7
  # @resp_changes 8
  # @resp_sync_diff 9
  @resp_error 10

  # ── Encoding ─────────────────────────────────────────────────────────

  @doc "Encode a request into a length-prefixed bincode frame."
  def encode_request(ref_id, request) do
    payload = encode_u64(ref_id) <> encode_request_body(request)
    <<byte_size(payload)::big-unsigned-32>> <> payload
  end

  defp encode_request_body({:put_blob, data}) do
    encode_variant(@put_blob) <> encode_bytes(data)
  end

  defp encode_request_body({:get_blob, hash}) do
    encode_variant(@get_blob) <> encode_bytes(hash)
  end

  defp encode_request_body({:has_blob, hash}) do
    encode_variant(@has_blob) <> encode_bytes(hash)
  end

  defp encode_request_body({:put_document, id, meta, crdt_state}) do
    encode_variant(@put_document) <>
      encode_string(id) <>
      encode_bytes(meta) <>
      encode_bytes(crdt_state)
  end

  defp encode_request_body({:get_document, id}) do
    encode_variant(@get_document) <> encode_string(id)
  end

  defp encode_request_body({:delete_document, id}) do
    encode_variant(@delete_document) <> encode_string(id)
  end

  defp encode_request_body(:list_documents) do
    encode_variant(@list_documents)
  end

  # ── Decoding ─────────────────────────────────────────────────────────

  @doc "Decode a bincode response payload (without length prefix) into {ref_id, response}."
  def decode_response(<<ref_id::little-unsigned-64, rest::binary>>) do
    {ref_id, decode_response_body(rest)}
  end

  defp decode_response_body(<<@resp_ok::little-unsigned-32>>) do
    :ok
  end

  defp decode_response_body(<<@resp_ok::little-unsigned-32, _rest::binary>>) do
    :ok
  end

  defp decode_response_body(<<@resp_blob::little-unsigned-32, rest::binary>>) do
    {data, _} = decode_bytes(rest)
    {:blob, data}
  end

  defp decode_response_body(<<@resp_blob_stored::little-unsigned-32, rest::binary>>) do
    {hash, _} = decode_bytes(rest)
    {:blob_stored, hash}
  end

  defp decode_response_body(<<@resp_blob_exists::little-unsigned-32, byte, _rest::binary>>) do
    {:blob_exists, byte == 1}
  end

  defp decode_response_body(<<@resp_document::little-unsigned-32, rest::binary>>) do
    {id, rest1} = decode_string(rest)
    {meta, rest2} = decode_bytes(rest1)
    {crdt_state, _} = decode_bytes(rest2)
    {:document, id, meta, crdt_state}
  end

  defp decode_response_body(<<@resp_document_list::little-unsigned-32, rest::binary>>) do
    {ids, _} = decode_string_list(rest)
    {:document_list, ids}
  end

  defp decode_response_body(<<@resp_not_found::little-unsigned-32, _rest::binary>>) do
    :not_found
  end

  defp decode_response_body(<<@resp_not_found::little-unsigned-32>>) do
    :not_found
  end

  defp decode_response_body(<<@resp_error::little-unsigned-32, rest::binary>>) do
    {message, _} = decode_string(rest)
    {:error, message}
  end

  # ── Primitives ───────────────────────────────────────────────────────

  defp encode_variant(idx), do: <<idx::little-unsigned-32>>

  defp encode_u64(n), do: <<n::little-unsigned-64>>

  defp encode_bytes(bin) when is_binary(bin) do
    <<byte_size(bin)::little-unsigned-64>> <> bin
  end

  # Bincode 1 encodes String identically to Vec<u8>
  defp encode_string(str) when is_binary(str), do: encode_bytes(str)

  defp decode_bytes(<<len::little-unsigned-64, rest::binary>>) do
    <<data::binary-size(len), remaining::binary>> = rest
    {data, remaining}
  end

  defp decode_string(bin), do: decode_bytes(bin)

  defp decode_string_list(<<count::little-unsigned-64, rest::binary>>) do
    decode_n_strings(rest, count, [])
  end

  defp decode_n_strings(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_n_strings(rest, n, acc) do
    {s, remaining} = decode_string(rest)
    decode_n_strings(remaining, n - 1, [s | acc])
  end
end
