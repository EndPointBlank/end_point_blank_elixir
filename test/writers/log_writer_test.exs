defmodule EndPointBlank.Writers.LogWriterTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.{Config, RequestStore}
  alias EndPointBlank.Writers.LogWriter

  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(app_name: "test-app", log_base_url: "https://log.test")

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

  defp written do
    assert_receive {:written, path, payload}
    %{path: path, payload: payload}
  end

  describe "levels" do
    for {fun, level} <- [info: "info", warn: "warn", error: "error", fatal: "fatal"] do
      test "#{fun}/1 is recorded at level #{level}" do
        apply(LogWriter, unquote(fun), ["a message"])

        %{payload: payload} = written()
        assert payload["log_level"] == unquote(level)
        assert payload["message"] == "a message"
      end
    end
  end

  test "posts to the application-logs endpoint" do
    LogWriter.info("hello")

    assert written().path == "/api/application_logs"
  end

  test "carries the structured data given alongside the message" do
    LogWriter.error("failed", %{reason: "timeout", attempts: 3})

    assert written().payload["data"] == %{"reason" => "timeout", "attempts" => 3}
  end

  test "ties the entry to the request it was written during" do
    # Without the uuid and environment id, a log line cannot be placed on the
    # request timeline it belongs to.
    RequestStore.put_uuid("uuid-1")
    RequestStore.put_source_env_id("app-env-1")

    LogWriter.info("hello")

    %{payload: payload} = written()
    assert payload["uuid"] == "uuid-1"
    assert payload["source_application_environment_id"] == "app-env-1"
    assert payload["app_name"] == "test-app"
  end

  test "stamps the path and method when a conn is in scope" do
    RequestStore.put_conn(Plug.Test.conn("POST", "/books"))

    LogWriter.info("hello")

    %{payload: payload} = written()
    assert payload["stamped_path"] == "/books"
    assert payload["stamped_http_method"] == "POST"
  end

  test "omits the stamps outside a request" do
    # Logs written from a worker or a task have no request to attribute to.
    LogWriter.info("hello")

    %{payload: payload} = written()
    refute Map.has_key?(payload, "stamped_path")
  end

  test "runs the user's mask hook over the entry before sending" do
    Config.update(mask_hook: fn payload, _type -> Map.put(payload, :message, "[masked]") end)

    LogWriter.info("secret value")

    assert written().payload["message"] == "[masked]"
  end
end
