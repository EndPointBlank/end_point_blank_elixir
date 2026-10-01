defmodule EndPointBlank.OutboundUrl do
  @moduledoc """
  The part of a caller's outbound URL the SDK may keep, send to intake, or
  log: scheme and host (both lowercased; IPv6 in brackets), port when it is
  not the scheme's default (`:443` for https, `:80` for http), and path.
  Userinfo, query and fragment are removed (sc-1469). An empty port
  (`https://api.test:/x`) counts as none, and a non-numeric one is refused.

  The caller controls the URL passed to `EndPointBlank.Authorization.header/1`,
  and any of those three parts can carry a secret. intake needs none of them --
  its base-URL normalizer refuses a URL carrying any of them, even an empty `?`
  or `#`, and answers 422 -- so sending them would both leak them and
  guarantee the mint fails. Built from the parsed parts rather than by
  splitting the string, so an empty `?` or `#` cannot slip through.

  The JS, Python, Java and Ruby SDKs strip the same parts and drop the same
  default ports. One difference: the Ruby SDK's `TargetUrl.strip` keeps the
  host's case as written, where this lowercases it.
  """

  @doc """
  Returns `{:ok, stripped}`, or `{:error, :invalid_base_url}` when `url` is not
  a non-empty string, does not parse, or has no scheme or host. An error means
  no request may be made for it.

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
        scheme = String.downcase(scheme, :ascii)
        host = String.downcase(host, :ascii)
        {:ok, "#{scheme}://#{bracket(host)}#{port_text(scheme, port)}#{path}"}

      _ ->
        {:error, :invalid_base_url}
    end
  end

  def strip(_url), do: {:error, :invalid_base_url}

  # URI keeps an IPv6 literal without its brackets.
  defp bracket(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  # URI fills in the scheme's default port when none was written, or an empty
  # one was, so a default port is omitted whether or not it was written out.
  defp port_text(scheme, port) when is_integer(port) do
    if port == URI.default_port(scheme), do: "", else: ":#{port}"
  end

  defp port_text(_scheme, _port), do: ""
end
