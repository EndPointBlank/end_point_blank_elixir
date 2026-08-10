defmodule EndPointBlank.Writers.RequestWriterTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.{Config, RequestStore}
  alias EndPointBlank.Writers.RequestWriter

  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(app_name: "test-app", environment: "test", log_base_url: "https://log.test")

    test_pid = self()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      %{"payload" => [payload]} = Jason.decode!(raw)
      send(test_pid, {:written, conn.request_path, payload})
      Req.Test.json(conn, %{"ok" => true})
    end)

    on_exit(fn ->
      Config.reset()
      RequestStore.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
      Req.Test.set_req_test_to_private()
    end)

    :ok
  end

  defp write(conn) do
    RequestWriter.write(conn)
    assert_receive {:written, path, payload}
    %{path: path, payload: payload}
  end

  test "posts to the application-requests endpoint" do
    assert write(Plug.Test.conn("GET", "/books")).path == "/api/application_requests"
  end

  test "describes the request that arrived" do
    RequestStore.put_uuid("uuid-1")

    %{payload: payload} =
      Plug.Test.conn("POST", "/books")
      |> Plug.Conn.put_req_header("x-api-version", "3")
      |> write()

    assert payload["app_name"] == "test-app"
    assert payload["env"] == "test"
    assert payload["uuid"] == "uuid-1"
    assert payload["path"] == "/books"
    assert payload["http_method"] == "POST"
    assert payload["endpoint_version"] == "3"
    assert payload["host"] == "www.example.com"
  end

  test "includes the request headers" do
    %{payload: payload} =
      Plug.Test.conn("GET", "/books")
      |> Plug.Conn.put_req_header("x-request-id", "abc")
      |> write()

    assert payload["headers"]["x-request-id"] == "abc"
  end

  test "sends the parsed body as JSON" do
    conn = %{Plug.Test.conn("POST", "/books") | body_params: %{"title" => "Dune"}}

    assert Jason.decode!(write(conn).payload["request"]) == %{"title" => "Dune"}
  end

  test "sends no body when the request had none" do
    conn = %{Plug.Test.conn("POST", "/books") | body_params: %{}}

    assert write(conn).payload["request"] == nil
  end

  test "sends no body when the params were never parsed" do
    assert write(Plug.Test.conn("GET", "/books")).payload["request"] == nil
  end

  test "truncates an oversized body instead of shipping it whole" do
    # An unbounded body would let one large upload dominate a batch and blow the
    # intake request size limit for every payload travelling with it.
    conn = %{
      Plug.Test.conn("POST", "/books")
      | body_params: %{"blob" => String.duplicate("x", 5_000)}
    }

    body = write(conn).payload["request"]

    assert String.ends_with?(body, "...")
    assert byte_size(body) == 1024 + 3
  end

  test "applies the configured masking rules before sending" do
    Config.update(
      masking_rules: [
        %{target: "request_body", path: "$.password", regex: nil, replacement_value: "[redacted]"}
      ]
    )

    conn = %{Plug.Test.conn("POST", "/login") | body_params: %{"password" => "hunter2"}}

    assert Jason.decode!(write(conn).payload["request"]) == %{"password" => "[redacted]"}
  end

  # Plug.Conn.put_req_header/3 refuses "host" outright -- it would be shadowed
  # by conn.host for a normal caller, which is exactly why BaseUrl reads the
  # raw header instead. List.keystore/4 mirrors what put_req_header does
  # internally, minus that guard, so these tests can still exercise a "host"
  # request header distinct from conn.host.
  defp put_raw_header(conn, name, value) do
    %{conn | req_headers: List.keystore(conn.req_headers, name, 0, {name, value})}
  end

  test "carries the resolved base URL fields" do
    # BaseUrl is covered on its own. This proves only that the writer calls it
    # -- a resolver nothing merges in ships nothing.
    conn = %{
      Plug.Test.conn("GET", "/books")
      | scheme: :https,
        host: "api.example.com",
        port: 8443
    }

    %{payload: payload} = write(put_raw_header(conn, "host", "API.Example.com:8443"))

    assert payload["scheme"] == "https"
    assert payload["host"] == "api.example.com"
    assert payload["port"] == 8443
  end

  test "omits a base URL field it cannot resolve rather than sending null" do
    conn = %{Plug.Test.conn("GET", "/books") | scheme: nil, host: nil, port: nil}

    payload = write(conn).payload

    refute Map.has_key?(payload, "host")
    refute Map.has_key?(payload, "scheme")
    refute Map.has_key?(payload, "port")
  end

  # The pair below is the wiring check for the flag: same proxied request, both
  # settings. If the writer ever stops passing the configured value through, the
  # second test reports api.example.com and fails.
  defp proxied_conn do
    %{Plug.Test.conn("GET", "/books") | scheme: :http, host: "internal.svc", port: 8080}
    |> put_raw_header("host", "internal.svc:8080")
    |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
    |> Plug.Conn.put_req_header("x-forwarded-host", "api.example.com")
    |> Plug.Conn.put_req_header("x-forwarded-port", "443")
  end

  test "reports the forwarded values when proxy headers are trusted" do
    Config.update(trust_proxy_headers: true)

    %{payload: payload} = write(proxied_conn())

    assert payload["scheme"] == "https"
    assert payload["host"] == "api.example.com"
    refute Map.has_key?(payload, "port")
  end

  test "reports the connection and Host header when proxy headers are not trusted" do
    Config.update(trust_proxy_headers: false)

    %{payload: payload} = write(proxied_conn())

    assert payload["scheme"] == "http"
    assert payload["host"] == "internal.svc"
    assert payload["port"] == 8080
  end
end
