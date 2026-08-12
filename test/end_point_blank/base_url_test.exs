defmodule EndPointBlank.BaseUrlTest do
  use ExUnit.Case, async: true

  alias EndPointBlank.BaseUrl

  # Built from a Plug.Test conn with the fields set by hand, because the point
  # of this module is that it reads the headers itself. Plug has no notion of a
  # trusted proxy, so conn.host/scheme/port describe the internal hop and
  # nothing else.
  defp conn(overrides \\ [], headers \\ []) do
    base = %{
      Plug.Test.conn("GET", "/orders")
      | scheme: :https,
        host: "api.example.com",
        port: 8443
    }

    conn = struct!(base, overrides)

    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_raw_header(acc, name, value)
    end)
  end

  # Plug.Conn.put_req_header/3 refuses "host" outright (raise: "set the host
  # header with %Plug.Conn{conn | host: ...}") because storing it in
  # req_headers would be shadowed by conn.host for every *normal* caller. That
  # is exactly the case this suite needs: BaseUrl reads the raw header on
  # purpose, and a real request from behind a proxy does carry a "host"
  # request header distinct from conn.host. List.keystore/4 mirrors what
  # put_req_header does internally, minus the guard.
  defp put_raw_header(conn, name, value) do
    %{conn | req_headers: List.keystore(conn.req_headers, name, 0, {name, value})}
  end

  test "resolves scheme host and port from a direct request" do
    resolved = BaseUrl.resolve(conn([], [{"host", "API.Example.com:8443"}]))

    assert resolved == %{scheme: "https", host: "api.example.com", port: 8443}
  end

  test "omits the port when it is the scheme default" do
    resolved = BaseUrl.resolve(conn([port: 443], [{"host", "api.example.com"}]))

    assert resolved == %{scheme: "https", host: "api.example.com"}
  end

  test "reports what the caller used, not what the process sees" do
    resolved =
      BaseUrl.resolve(
        conn([scheme: :http, port: 8080], [
          {"host", "internal.svc:8080"},
          {"x-forwarded-proto", "https"},
          {"x-forwarded-host", "api.example.com"},
          {"x-forwarded-port", "443"}
        ])
      )

    assert resolved == %{scheme: "https", host: "api.example.com"}
  end

  test "omits the connection port once a proxy is in front" do
    # 8080 is the internal listener. The caller never saw it, so reporting it
    # would be worse than reporting nothing.
    resolved =
      BaseUrl.resolve(
        conn([scheme: :http, port: 8080], [
          {"host", "api.example.com"},
          {"x-forwarded-proto", "https"}
        ])
      )

    assert resolved == %{scheme: "https", host: "api.example.com"}
  end

  test "takes the last forwarded hop so a caller cannot prepend its own" do
    # A proxy that appends writes its own observation last; a value the caller
    # planted arrives to the left of it.
    resolved =
      BaseUrl.resolve(
        conn([], [
          {"x-forwarded-proto", "https, http"},
          {"x-forwarded-host", "evil.example, api.example.com"}
        ])
      )

    assert resolved[:scheme] == "http"
    assert resolved[:host] == "api.example.com"
  end

  test "omits a field it cannot resolve rather than reporting null" do
    bare = %{Plug.Test.conn("GET", "/orders") | scheme: nil, host: nil, port: nil}

    assert BaseUrl.resolve(bare) == %{}
    assert BaseUrl.resolve(:not_a_conn) == %{}
  end

  test "drops a host that is not shaped like a hostname" do
    resolved = BaseUrl.resolve(conn([], [{"host", "api.example.com/../evil?x=1"}]))

    refute Map.has_key?(resolved, :host)
    assert resolved == %{scheme: "https", port: 8443}
  end

  test "ignores the forwarded headers when proxy headers are not trusted" do
    # Same request as "reports what the caller used", resolved both ways, so
    # the only difference between the two expectations is the flag. Off, the
    # request is not proxied at all, so 8080 is evidence again.
    proxied =
      conn([scheme: :http, port: 8080], [
        {"host", "internal.svc:8080"},
        {"x-forwarded-proto", "https"},
        {"x-forwarded-host", "api.example.com"},
        {"x-forwarded-port", "443"}
      ])

    assert BaseUrl.resolve(proxied, true) == %{scheme: "https", host: "api.example.com"}
    assert BaseUrl.resolve(proxied, false) == %{scheme: "http", host: "internal.svc", port: 8080}
  end

  test "normalizes the scheme to lowercase without a trailing colon" do
    # JS's location.protocol and Node's URL#protocol both yield "https:", and
    # nothing pins the case. intake never rewrites a stored row, so the first
    # release's spelling is permanent -- normalize on the way out.
    assert BaseUrl.resolve(conn([], [{"x-forwarded-proto", "HTTPS"}]))[:scheme] == "https"
    assert BaseUrl.resolve(conn([], [{"x-forwarded-proto", "https:"}]))[:scheme] == "https"
  end

  test "keeps an IPv6 literal whole and splits its port off" do
    resolved = BaseUrl.resolve(conn([], [{"host", "[2001:DB8::1]:8443"}]))

    assert resolved == %{scheme: "https", host: "[2001:db8::1]", port: 8443}
  end

  test "omits the port when the scheme cannot be resolved, even with a syntactically valid forwarded port" do
    # X-Forwarded-Port "443" parses fine on its own, but with no
    # X-Forwarded-Proto the scheme is unresolved, so there is nothing to
    # classify 443 against (default for https, not for http). Reporting it
    # anyway would let the same origin be written two ways depending on
    # whether a proxy happened to also send X-Forwarded-Proto -- never
    # synthesize or infer, omit instead.
    resolved =
      BaseUrl.resolve(
        conn([], [
          {"x-forwarded-host", "api.example.com"},
          {"x-forwarded-port", "443"}
        ])
      )

    assert resolved == %{host: "api.example.com"}
  end

  test "ignores a malformed forwarded port rather than blanking the port and scheme" do
    # X-Forwarded-Port is garbage and stands alone -- no X-Forwarded-Proto, no
    # X-Forwarded-Host -- so nothing here counts as proxy evidence. The request
    # resolves exactly as if the header were never sent: scheme from the
    # connection, host and port from the Host header's authority.
    resolved =
      BaseUrl.resolve(
        conn([port: 8080], [
          {"host", "api.example.com:9000"},
          {"x-forwarded-port", "not-a-port"}
        ])
      )

    assert resolved == %{scheme: "https", host: "api.example.com", port: 9000}
  end

  test "ignores a malformed forwarded proto rather than erasing the scheme" do
    # X-Forwarded-Proto is garbage, so it is not proxy evidence either -- only
    # X-Forwarded-Host is valid evidence here, and (unlike scheme/port) a valid
    # X-Forwarded-Host was never sufficient on its own to distrust the
    # connection's scheme. The junk proto falls out of the picture entirely
    # rather than forcing the scheme to be omitted.
    resolved =
      BaseUrl.resolve(
        conn([], [
          {"x-forwarded-proto", "not a scheme"},
          {"x-forwarded-host", "api.example.com"}
        ])
      )

    assert resolved[:scheme] == "https"
    assert resolved[:host] == "api.example.com"
  end

  test "drops a forwarded host longer than a DNS hostname can be" do
    # DNS caps a hostname at 253 characters. X-Forwarded-Host gets no length
    # validation from Bandit or Cowboy, so without this check a caller could
    # make the SDK report an arbitrarily long host. Dropped, not truncated --
    # a truncated value would look like a plausible, wrong host.
    long_host = String.duplicate("a", 300)

    resolved =
      BaseUrl.resolve(
        conn([host: nil], [
          {"x-forwarded-proto", "https"},
          {"x-forwarded-host", long_host}
        ])
      )

    refute Map.has_key?(resolved, :host)
    assert resolved[:scheme] == "https"
  end

  test "keeps a host at exactly the DNS length limit and drops one byte over" do
    at_limit = String.duplicate("a", 253)
    over_limit = String.duplicate("a", 254)

    assert BaseUrl.resolve(conn([], [{"host", at_limit}]))[:host] == at_limit
    refute BaseUrl.resolve(conn([], [{"host", over_limit}])) |> Map.has_key?(:host)
  end

  test "an empty host header falls through to conn.host" do
    # The cross-SDK contract: an empty Host header is absent, not
    # present-but-unusable, in all five clients. This is a deliberate change
    # from Elixir's previous behavior -- "" is truthy here, so it used to stop
    # the fallback and resolve the host to nil.
    resolved = BaseUrl.resolve(conn([host: "internal.svc"], [{"host", ""}]))

    assert resolved == %{scheme: "https", host: "internal.svc", port: 8443}
  end

  test "hostname lowercases the host and strips the port" do
    assert BaseUrl.hostname(conn([], [{"host", "API.Example.com:8443"}])) == "api.example.com"
  end

  test "hostname keeps an IPv6 literal whole and bracketed" do
    resolved = BaseUrl.hostname(conn([], [{"host", "[2001:DB8::1]:8443"}]))

    assert resolved == "[2001:db8::1]"
  end

  test "hostname ignores X-Forwarded-Host even though resolve honors it" do
    # target_hostname is the portal's application-environment lookup key. A
    # value matching no registered row is a hard 422, not a cache miss.
    proxied =
      conn([], [
        {"host", "internal.svc"},
        {"x-forwarded-host", "api.example.com"}
      ])

    assert BaseUrl.hostname(proxied) == "internal.svc"
    assert BaseUrl.resolve(proxied)[:host] == "api.example.com"
  end

  test "hostname falls back to conn.host when there is no host header" do
    assert BaseUrl.hostname(conn(host: "internal.svc")) == "internal.svc"
  end

  test "hostname falls through to conn.host when the host header is empty" do
    assert BaseUrl.hostname(conn([host: "internal.svc"], [{"host", ""}])) == "internal.svc"
  end

  test "hostname is nil when the host header is empty and conn.host is unusable" do
    assert BaseUrl.hostname(conn([host: nil], [{"host", ""}])) == nil
  end

  test "hostname is nil for a host that is not shaped like a hostname" do
    resolved = BaseUrl.hostname(conn([], [{"host", "api.example.com/../evil?x=1"}]))

    assert resolved == nil
  end

  test "hostname is nil for a host longer than DNS allows" do
    long_host = String.duplicate("a", 300)

    assert BaseUrl.hostname(conn([], [{"host", long_host}])) == nil
  end

  test "hostname is nil when handed something that is not a conn" do
    assert BaseUrl.hostname(:not_a_conn) == nil
  end

  # Cowboy, Bandit and Plug.Test.conn/2 all strip the brackets off an IPv6
  # literal before setting conn.host, so a real IPv6 request arrives as the
  # bare "2001:db8::1" -- not "[2001:db8::1]". Without re-bracketing here,
  # this SDK would report nil for exactly the requests the other four SDKs
  # report a bracketed literal for.
  test "hostname re-brackets an IPv6 literal that arrived on conn.host without brackets" do
    assert BaseUrl.hostname(conn(host: "2001:db8::1")) == "[2001:db8::1]"
  end
end
