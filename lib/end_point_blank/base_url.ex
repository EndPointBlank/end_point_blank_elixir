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
    forwarded_scheme =
      if trust_proxy_headers, do: clean_scheme(last_hop(header(conn, "x-forwarded-proto")))

    forwarded_port =
      if trust_proxy_headers, do: parse_port(last_hop(header(conn, "x-forwarded-port")))

    # host is never proxy-gated the way scheme/port are below: it was already
    # caller-controlled before this feature existed (conn.host comes straight
    # from the Host header), so a valid X-Forwarded-Host says nothing new about
    # whether the connection's scheme/port can still be trusted. Only a
    # validated forwarded scheme or port does that -- see `proxied` below.
    forwarded_authority =
      if trust_proxy_headers, do: usable_authority(last_hop(header(conn, "x-forwarded-host")))

    # A forwarded header counts as evidence of a proxy only once its last hop
    # has parsed into something usable for that field. A blank, whitespace-only
    # or malformed value is indistinguishable from the header never having been
    # sent at all, and must not block the fallback below for any field --
    # including its own (an attacker sending garbage in one header should not
    # be able to blank a field a legitimate value would have supplied).
    proxied = not is_nil(forwarded_scheme) or not is_nil(forwarded_port)

    {host_part, authority_port} =
      forwarded_authority || split_authority(host_header(conn) || conn.host)

    scheme = forwarded_scheme || if(proxied, do: nil, else: clean_scheme(conn.scheme))
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

  @doc """
  The hostname alone, for the authorize path.

  Deliberately not `resolve/2`'s `:host`: reads the `host` header only, never
  the forwarded chain, whatever `trust_proxy_headers` is set to. The value feeds
  `target_hostname` and the access-token cache key, and the portal resolves an
  application environment from it -- a value matching no registered row is a
  hard 422 with no fallback, not a cache miss.

  Composed from the same `split_authority/1` and `clean_host/1` pair `resolve/2`
  uses, so lowercasing and shape and length validation are identical between the
  two; only the authority's source differs, plus the IPv6 fix-up below.
  """
  @spec hostname(Plug.Conn.t() | any()) :: String.t() | nil
  def hostname(%Plug.Conn{} = conn) do
    {host_part, _authority_port} =
      split_authority(host_header(conn) || bracket_ipv6(conn.host))

    clean_host(host_part)
  end

  def hostname(_), do: nil

  # Cowboy, Bandit and Plug.Test all strip the brackets off an IPv6 literal
  # before setting conn.host, so the bare form is what a real IPv6 request
  # arrives as -- and clean_host/1 requires brackets, since a bare literal is
  # indistinguishable from a malformed name. Restore them rather than dropping
  # the host, so this SDK reports what the other four report.
  defp bracket_ipv6(value) when is_binary(value) do
    cond do
      String.starts_with?(value, "[") -> value
      length(String.split(value, ":")) > 2 -> "[" <> value <> "]"
      true -> value
    end
  end

  defp bracket_ipv6(other), do: other

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  # The single site where both resolve/2 and hostname/1 decide what an empty
  # `Host:` means. It means absent, not present-but-unusable: a caller that
  # sent the header with nothing after it has said nothing about which host it
  # meant, so there is nothing here to prefer over conn.host. Falling through
  # concedes no control either -- conn.host is a server-side value the caller
  # cannot steer, so it hands the caller nothing it did not already have.
  #
  # On the authorize path the alternative is worse than cosmetic: resolving to
  # nil there drops the request to Basic auth and skips the token mint,
  # whereas falling through yields a usable application-environment lookup key.
  #
  # This CHANGES this SDK's behavior -- an empty Host header used to resolve
  # the host to nil, because "" is truthy in Elixir and so stopped the `||`
  # chain here. Python, Java and JS already fell through, "" being falsy
  # there; Ruby stopped for the same reason Elixir did. One expression written
  # five times, agreeing everywhere except the empty case. It now lives at one
  # site per SDK, and this comment is why.
  defp host_header(conn) do
    case header(conn, "host") do
      "" -> nil
      other -> other
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

  # Validates an x-forwarded-host value the same way the final host is
  # validated, so a malformed value can't win the authority fallback in
  # resolve/2 and lock out the literal Host header (or conn.host) it should
  # have fallen through to instead.
  defp usable_authority(nil), do: nil

  defp usable_authority(value) do
    {host_part, port_part} = split_authority(value)
    if clean_host(host_part), do: {host_part, port_part}
  end

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
      # DNS caps a hostname at 253 characters, so anything longer cannot be a
      # real hostname -- X-Forwarded-Host gets no length validation from
      # Bandit or Cowboy, so without this a caller could make the SDK report
      # an arbitrarily long host. Dropped rather than truncated: a truncated
      # value would look like a plausible, wrong host, and the portal reads
      # this field verbatim to assemble a base URL.
      byte_size(host) > 253 -> nil
      Regex.match?(~r/\A[a-z0-9._-]+\z/, host) -> host
      Regex.match?(~r/\A\[[0-9a-f:.]+\]\z/, host) -> host
      true -> nil
    end
  end

  defp clean_host(_), do: nil

  # Digit-shape and range check only, independent of scheme -- used both to
  # decide whether a forwarded port counts as proxy evidence in resolve/2 and
  # as the first stage of clean_port/2 below.
  defp parse_port(value) when is_integer(value) do
    if value >= 1 and value <= 65_535, do: value
  end

  defp parse_port(value) when is_binary(value) do
    raw = String.trim(value)
    if Regex.match?(~r/\A[0-9]{1,5}\z/, raw), do: parse_port(String.to_integer(raw))
  end

  defp parse_port(_), do: nil

  defp clean_port(value, scheme) do
    case parse_port(value) do
      nil -> nil
      port -> usable_port(port, scheme)
    end
  end

  # A port can only be judged "the scheme's default, so omit it" once the
  # scheme itself is known. An unresolved scheme leaves a parsed port with
  # nothing to classify it against -- reporting it anyway would let the same
  # origin be written two ways depending on whether a proxy happened to also
  # send X-Forwarded-Proto. Never synthesize or infer: omit rather than guess.
  defp usable_port(_port, nil), do: nil

  defp usable_port(port, scheme) do
    if Map.get(@default_ports, scheme) == port, do: nil, else: port
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
