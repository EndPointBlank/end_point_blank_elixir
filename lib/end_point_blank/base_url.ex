defmodule EndPointBlank.BaseUrl do
  @moduledoc """
  Resolves the base URL the caller used -- scheme, host and port -- from a
  `Plug.Conn`.

  This reads the request headers directly rather than trusting `conn.scheme`,
  `conn.host` and `conn.port`. Plug has no notion of a trusted proxy at all
  unless the host application installs `Plug.RewriteOn` itself, so those three
  describe the internal hop and nothing else. More generally: Rack, Express, the
  servlet spec and Plug each resolve "host" differently (Rack takes the last
  `X-Forwarded-Host` hop, Express the first, WSGI and Plug neither), which is why
  the same request produced five different answers across the five clients.

  Forwarded headers are honored when `trust_proxy_headers` is on, which it is by
  default, taking the LAST hop: `host` was already caller-controlled in every
  client (`conn.host` comes from the `Host` header), and behind a proxy that
  appends, the last value is the proxy's own observation rather than anything the
  caller planted. A directly-exposed deployment can pass `false` and get scheme,
  host and port from the conn and the `Host` header only.

  The flag arrives as an argument rather than being read from
  `EndPointBlank.Config` here, so that this module stays configuration-free and
  both states are directly testable.
  """

  @default_ports %{"http" => 80, "https" => 443}

  @doc """
  Returns a map carrying only the fields that resolved to a usable value.

  A field that could not be resolved is absent, never `nil`: the receiver has to
  be able to tell "this SDK did not report a port" from "the port is null".

  With `trust_proxy_headers` false the three `x-forwarded-*` headers are not read
  at all, so the request is never treated as proxied and `conn.scheme` and
  `conn.port` stay evidence.
  """
  @spec resolve(Plug.Conn.t() | any(), boolean()) :: map()
  def resolve(conn, trust_proxy_headers \\ true)

  def resolve(%Plug.Conn{} = conn, trust_proxy_headers) do
    forwarded_proto = if trust_proxy_headers, do: last_hop(header(conn, "x-forwarded-proto"))
    forwarded_host = if trust_proxy_headers, do: last_hop(header(conn, "x-forwarded-host"))
    forwarded_port = if trust_proxy_headers, do: last_hop(header(conn, "x-forwarded-port"))

    proxied =
      not is_nil(forwarded_proto) or not is_nil(forwarded_host) or not is_nil(forwarded_port)

    {host_part, authority_port} =
      split_authority(forwarded_host || header(conn, "host") || conn.host)

    scheme = clean_scheme(forwarded_proto || if(proxied, do: nil, else: conn.scheme))
    host = clean_host(host_part)

    port =
      clean_port(
        forwarded_port || authority_port || if(proxied, do: nil, else: conn.port),
        scheme
      )

    %{}
    |> put_present(:scheme, scheme)
    |> put_present(:host, host)
    |> put_present(:port, port)
  end

  def resolve(_, _), do: %{}

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  # A proxy that appends writes its own observation last. A proxy that
  # overwrites (nginx, Caddy, ALB) emits one value, where first and last are the
  # same thing.
  defp last_hop(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end

  defp last_hop(_), do: nil

  # "api.example.com:8443" -> {"api.example.com", "8443"}
  # "[2001:db8::1]:8443"   -> {"[2001:db8::1]", "8443"}
  defp split_authority(value) when is_binary(value) do
    authority = String.trim(value)

    cond do
      String.starts_with?(authority, "[") ->
        case String.split(authority, "]", parts: 2) do
          [head, ":" <> port] -> {head <> "]", port}
          [head, _rest] -> {head <> "]", nil}
          _ -> {nil, nil}
        end

      length(String.split(authority, ":")) == 2 ->
        [host, port] = String.split(authority, ":")
        {host, port}

      true ->
        {authority, nil}
    end
  end

  defp split_authority(_), do: {nil, nil}

  defp clean_scheme(value) when is_atom(value) and not is_nil(value),
    do: clean_scheme(Atom.to_string(value))

  # Normalize, then validate. "HTTPS" and "https:" both have to reach intake as
  # "https": JS's location.protocol and Node's URL#protocol keep the colon,
  # nothing pins the case, and intake never rewrites a stored row -- two
  # spellings of one scheme would split the grouping forever.
  # replace_suffix/3 removes one colon, not all of them, so "https::" still
  # fails the shape check rather than sneaking through.
  defp clean_scheme(value) when is_binary(value) do
    scheme =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace_suffix(":", "")

    if Regex.match?(~r/\A[a-z][a-z0-9+.-]{0,31}\z/, scheme), do: scheme, else: nil
  end

  defp clean_scheme(_), do: nil

  defp clean_host(value) when is_binary(value) do
    host = value |> String.trim() |> String.downcase()

    cond do
      host == "" -> nil
      Regex.match?(~r/\A[a-z0-9._-]+\z/, host) -> host
      Regex.match?(~r/\A\[[0-9a-f:.]+\]\z/, host) -> host
      true -> nil
    end
  end

  defp clean_host(_), do: nil

  defp clean_port(value, scheme) when is_integer(value), do: usable_port(value, scheme)

  defp clean_port(value, scheme) when is_binary(value) do
    raw = String.trim(value)

    if Regex.match?(~r/\A[0-9]{1,5}\z/, raw),
      do: usable_port(String.to_integer(raw), scheme),
      else: nil
  end

  defp clean_port(_, _), do: nil

  defp usable_port(port, _scheme) when port < 1 or port > 65_535, do: nil

  defp usable_port(port, scheme) do
    if Map.get(@default_ports, scheme) == port, do: nil, else: port
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
