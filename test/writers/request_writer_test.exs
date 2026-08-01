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
end
