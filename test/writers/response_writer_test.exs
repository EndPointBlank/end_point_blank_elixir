defmodule EndPointBlank.Writers.ResponseWriterTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.{Config, RequestStore}
  alias EndPointBlank.Writers.ResponseWriter

  setup do
    Req.Test.set_req_test_to_shared()

    Application.put_env(
      :end_point_blank_elixir,
      :req_test_plug,
      {Req.Test, __MODULE__.ResponsesStub}
    )

    on_exit(fn ->
      Config.reset()
      RequestStore.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
      Req.Test.set_req_test_to_private()
    end)

    :ok
  end

  defp capture_payload do
    test_pid = self()

    Req.Test.stub(__MODULE__.ResponsesStub, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      %{"payload" => [payload]} = Jason.decode!(raw_body)
      send(test_pid, {:captured_payload, payload})
      Req.Test.json(conn, %{"ok" => true})
    end)
  end

  test "sends the response's HTTP method alongside route" do
    capture_payload()

    conn =
      Plug.Test.conn("GET", "/x")
      |> Plug.Conn.put_private(:epb_route, "/x")
      |> Plug.Conn.resp(200, "")

    ResponseWriter.write(conn)

    assert_receive {:captured_payload, payload}
    assert payload["route"] == "/x"
    assert payload["method"] == "GET"
  end

  test "reflects whatever HTTP method the conn carries" do
    capture_payload()

    conn =
      Plug.Test.conn("POST", "/y")
      |> Plug.Conn.put_private(:epb_route, "/y")
      |> Plug.Conn.resp(201, "")

    ResponseWriter.write(conn)

    assert_receive {:captured_payload, payload}
    assert payload["route"] == "/y"
    assert payload["method"] == "POST"
  end

  test "falls back to the request path when no route was stamped" do
    capture_payload()

    ResponseWriter.write(Plug.Conn.resp(Plug.Test.conn("GET", "/unrouted"), 200, ""))

    assert_receive {:captured_payload, payload}
    assert payload["route"] == "/unrouted"
  end

  test "records the status, headers and environment id" do
    capture_payload()
    RequestStore.put_uuid("uuid-1")
    RequestStore.put_source_env_id("app-env-1")

    conn =
      Plug.Test.conn("GET", "/x")
      |> Plug.Conn.put_resp_header("x-trace", "abc")
      |> Plug.Conn.resp(404, "nope")

    ResponseWriter.write(conn)

    assert_receive {:captured_payload, payload}
    assert payload["status"] == 404
    assert payload["headers"]["x-trace"] == "abc"
    assert payload["uuid"] == "uuid-1"
    assert payload["source_application_environment_id"] == "app-env-1"
  end

  describe "the response body" do
    test "is sent as-is for an ordinary binary body" do
      capture_payload()

      ResponseWriter.write(Plug.Conn.resp(Plug.Test.conn("GET", "/x"), 200, "hello"))

      assert_receive {:captured_payload, payload}
      assert payload["body"] == "hello"
    end

    test "is flattened when the response was built as an iolist" do
      # Plug lets a response body be iodata, and Jason cannot encode a nested
      # charlist as a string — this has broken the writer before.
      capture_payload()

      conn = %{Plug.Test.conn("GET", "/x") | resp_body: ["he", ["ll", "o"]]}

      ResponseWriter.write(conn)

      assert_receive {:captured_payload, payload}
      assert payload["body"] == "hello"
    end

    test "is nil when the response carried no body at all" do
      capture_payload()

      ResponseWriter.write(Plug.Test.conn("GET", "/x"))

      assert_receive {:captured_payload, payload}
      assert payload["body"] == nil
    end

    test "is truncated rather than shipped whole when oversized" do
      capture_payload()

      body = String.duplicate("x", 5_000)
      ResponseWriter.write(Plug.Conn.resp(Plug.Test.conn("GET", "/x"), 200, body))

      assert_receive {:captured_payload, payload}
      assert String.ends_with?(payload["body"], "...")
      assert byte_size(payload["body"]) == 1024 + 3
    end

    test "is masked by a rule targeting the response body" do
      Config.update(
        masking_rules: [
          %{target: "response_body", path: "$.token", regex: nil, replacement_value: "[redacted]"}
        ]
      )

      capture_payload()

      conn = Plug.Conn.resp(Plug.Test.conn("GET", "/x"), 200, ~s({"token":"secret"}))
      ResponseWriter.write(conn)

      assert_receive {:captured_payload, payload}
      assert Jason.decode!(payload["body"]) == %{"token" => "[redacted]"}
    end
  end
end
