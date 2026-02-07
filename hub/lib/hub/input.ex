defmodule Hub.Input do
  @moduledoc """
  Input sanitization and validation utilities for RingForge.

  Provides functions to sanitize user input, preventing XSS, injection,
  and SSRF attacks. Apply in FleetChannel handlers and API controllers.
  """

  @max_default_string_length 10_000
  @max_tag_items 20
  @max_tag_length 50

  # Private IP ranges (for SSRF prevention)
  @private_ranges [
    # 10.0.0.0/8
    {10, 0, 0, 0, 8},
    # 172.16.0.0/12
    {172, 16, 0, 0, 12},
    # 192.168.0.0/16
    {192, 168, 0, 0, 16},
    # 127.0.0.0/8 (loopback)
    {127, 0, 0, 0, 8},
    # 169.254.0.0/16 (link-local)
    {169, 254, 0, 0, 16},
    # 0.0.0.0/8
    {0, 0, 0, 0, 8}
  ]

  @doc """
  Sanitize a string input: strip control characters and enforce max length.

  ## Options

    - `max_length` — maximum allowed length (default: #{@max_default_string_length})

  ## Examples

      iex> Hub.Input.sanitize_string("hello\\x00world", 100)
      {:ok, "helloworld"}

      iex> Hub.Input.sanitize_string(nil, 100)
      {:ok, nil}
  """
  def sanitize_string(nil, _max_length), do: {:ok, nil}
  def sanitize_string("", _max_length), do: {:ok, ""}

  def sanitize_string(input, max_length \\ @max_default_string_length) when is_binary(input) do
    sanitized =
      input
      # Strip control characters (except newline, tab)
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
      # Strip null bytes
      |> String.replace(<<0>>, "")
      # Trim whitespace
      |> String.trim()
      # Enforce max length
      |> String.slice(0, max_length)

    {:ok, sanitized}
  end

  def sanitize_string(_, _), do: {:error, :invalid_input}

  @doc """
  Sanitize a list of tags.

  - Maximum #{@max_tag_items} tags
  - Each tag maximum #{@max_tag_length} characters
  - Strips control characters from each tag
  - Rejects empty tags

  ## Examples

      iex> Hub.Input.sanitize_tags(["valid", "tag"])
      {:ok, ["valid", "tag"]}

      iex> Hub.Input.sanitize_tags(List.duplicate("x", 25))
      {:error, :too_many_tags}
  """
  def sanitize_tags(nil), do: {:ok, []}
  def sanitize_tags(tags) when is_list(tags) do
    if length(tags) > @max_tag_items do
      {:error, :too_many_tags}
    else
      sanitized =
        tags
        |> Enum.map(fn tag ->
          case sanitize_string(to_string(tag), @max_tag_length) do
            {:ok, s} -> s
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {:ok, sanitized}
    end
  end

  def sanitize_tags(_), do: {:error, :invalid_tags}

  @doc """
  Validate a URL for safety.

  - Must use HTTPS (or HTTP in dev/test)
  - Must not point to private/internal IPs (SSRF prevention)
  - Must have a valid host

  ## Examples

      iex> Hub.Input.validate_url("https://example.com/webhook")
      :ok

      iex> Hub.Input.validate_url("http://192.168.1.1/internal")
      {:error, :private_ip}

      iex> Hub.Input.validate_url("ftp://example.com")
      {:error, :invalid_scheme}
  """
  def validate_url(nil), do: {:error, :missing_url}

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["https", "http"] ->
        {:error, :invalid_scheme}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :missing_host}

      uri.scheme == "http" and Mix.env() == :prod ->
        {:error, :https_required}

      is_private_ip?(uri.host) ->
        {:error, :private_ip}

      true ->
        :ok
    end
  rescue
    _ -> {:error, :invalid_url}
  end

  def validate_url(_), do: {:error, :invalid_url}

  @doc """
  Sanitize a map of input, applying string sanitization to all string values.
  """
  def sanitize_map(nil), do: {:ok, %{}}
  def sanitize_map(map) when is_map(map) do
    sanitized =
      Enum.reduce(map, %{}, fn {key, value}, acc ->
        sanitized_value =
          case value do
            v when is_binary(v) ->
              case sanitize_string(v) do
                {:ok, s} -> s
                _ -> v
              end

            v when is_list(v) ->
              Enum.map(v, fn item ->
                case sanitize_string(to_string(item), @max_tag_length) do
                  {:ok, s} -> s
                  _ -> item
                end
              end)

            v ->
              v
          end

        Map.put(acc, key, sanitized_value)
      end)

    {:ok, sanitized}
  end

  def sanitize_map(_), do: {:error, :invalid_input}

  # ── Private: SSRF Prevention ───────────────────────────────

  defp is_private_ip?(host) do
    case resolve_host(host) do
      {:ok, ip_tuple} -> ip_in_private_range?(ip_tuple)
      _ -> false
    end
  end

  defp resolve_host(host) do
    charlist = String.to_charlist(host)

    # First try parsing as IP literal
    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        {:ok, ip}

      _ ->
        # DNS resolve
        case :inet.getaddr(charlist, :inet) do
          {:ok, ip} -> {:ok, ip}
          _ -> {:error, :unresolvable}
        end
    end
  end

  defp ip_in_private_range?({a, b, c, d}) do
    Enum.any?(@private_ranges, fn {ra, rb, rc, rd, bits} ->
      mask = bsl(0xFFFFFFFF, 32 - bits) |> band(0xFFFFFFFF)
      ip_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
      range_int = bsl(ra, 24) + bsl(rb, 16) + bsl(rc, 8) + rd
      band(ip_int, mask) == band(range_int, mask)
    end)
  end

  defp ip_in_private_range?(_), do: false

  defp band(a, b), do: Bitwise.band(a, b)
  defp bsl(a, b), do: Bitwise.bsl(a, b)
end
