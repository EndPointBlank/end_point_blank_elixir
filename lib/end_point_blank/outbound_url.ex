defmodule EndPointBlank.OutboundUrl do
  @moduledoc """
  The part of a caller's outbound URL the SDK may keep, send to intake, or
  log: scheme and host (both lowercased; IPv6 in brackets), port when it is
  not the scheme's default (`:443` for https, `:80` for http), and path.
  Userinfo, query and fragment are removed (sc-1469). An empty port
  (`https://api.test:/x`) counts as none. Refused: any scheme other than
  `http` or `https`, and a port that is not a number from 1 to 65535.

  The caller controls the URL passed to `EndPointBlank.Authorization.header/1`,
  and any of those three parts can carry a secret. intake needs none of them --
  its base-URL normalizer refuses a URL carrying any of them, even an empty `?`
  or `#`, and answers 422 -- so sending them would both leak them and
  guarantee the mint fails. Built from the parsed parts rather than by
  splitting the string, so an empty `?` or `#` cannot slip through.

  The same rule as the Ruby SDK's `TargetUrl.strip` (rails#43) and the JS,
  Python and Java SDKs' equivalents.
  """

  @doc """
  Returns `{:ok, stripped}`, or `{:error, :invalid_base_url}` when `url` is not
  a non-empty string, does not parse, has no host, has a scheme other than
  `http` or `https`, or has a port outside 1..65535. An error means no request
  may be made for it.

      iex> EndPointBlank.OutboundUrl.strip("https://u:p@api.test:8443/v1/things?key=s#frag")
      {:ok, "https://api.test:8443/v1/things"}

  The path is kept raw, exactly as written; it is not downcased or decoded.
  """
  @spec strip(term()) :: {:ok, String.t()} | {:error, :invalid_base_url}
  def strip(url) when is_binary(url) and url != "" do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port, path: path}}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        # URI.new/1 refuses a non-numeric port and downcases the scheme, but
        # keeps the host as written; both are downcased here regardless.
        build(String.downcase(scheme, :ascii), String.downcase(host, :ascii), port, path)

      _ ->
        {:error, :invalid_base_url}
    end
  end

  def strip(_url), do: {:error, :invalid_base_url}

  # Only http and https are ever a provider, and both always have a port once
  # parsed: URI fills in the default when none, or an empty one, was written.
  # A port outside 1..65535 parses as an integer all the same, so it is
  # refused here rather than sent to intake.
  defp build(scheme, host, port, path)
       when scheme in ["http", "https"] and is_integer(port) and port in 1..65_535 do
    {:ok, "#{scheme}://#{bracket(host)}#{port_text(scheme, port)}#{path}"}
  end

  defp build(_scheme, _host, _port, _path), do: {:error, :invalid_base_url}

  # URI keeps an IPv6 literal without its brackets.
  defp bracket(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  # A default port is omitted whether or not it was written out.
  defp port_text(scheme, port) do
    if port == URI.default_port(scheme), do: "", else: ":#{port}"
  end
end
