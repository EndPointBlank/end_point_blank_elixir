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
end
