defmodule EndPointBlank.Plug.ReportInteractionTest do
  @moduledoc """
  Reporting runs on every request in the host application, so the properties
  that matter are the ones that would damage the host: the per-request store
  must be emptied when the response is sent, and a failure inside reporting
  must surface rather than be swallowed.
  """
  use ExUnit.Case, async: false

  alias EndPointBlank.{Config, RequestStore}
  alias EndPointBlank.Plug.ReportInteraction

  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})

    Config.update(
      app_name: "test-app",
      environment: "test",
      base_url: "https://intake.test",
      log_base_url: "https://log.test"
    )

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

  defp run(conn) do
    conn
    |> ReportInteraction.call(ReportInteraction.init([]))
    |> Plug.Conn.send_resp(200, "hello")
  end

  describe "the request report" do
    test "is written as soon as the request arrives" do
      ReportInteraction.call(Plug.Test.conn("GET", "/books"), [])

      assert_receive {:written, "/api/application_requests", payload}
      assert payload["path"] == "/books"
      assert payload["http_method"] == "GET"
      assert payload["app_name"] == "test-app"
      assert payload["env"] == "test"
    end

    test "carries a uuid that the response report repeats" do
      # The uuid is the only thing tying a request row to its response row.
      run(Plug.Test.conn("GET", "/books"))

      assert_receive {:written, "/api/application_requests", request}
      assert_receive {:written, "/api/application_responses", response}

      assert is_binary(request["uuid"])
      assert response["uuid"] == request["uuid"]
    end

    test "gives each request its own uuid" do
      run(Plug.Test.conn("GET", "/books"))
      assert_receive {:written, "/api/application_requests", first}
      _ = drain()

      run(Plug.Test.conn("GET", "/books"))
      assert_receive {:written, "/api/application_requests", second}

      refute first["uuid"] == second["uuid"]
    end
  end

  describe "the response report" do
    test "is written when the response is sent, not before" do
      conn = ReportInteraction.call(Plug.Test.conn("GET", "/books"), [])

      assert_receive {:written, "/api/application_requests", _}
      refute_received {:written, "/api/application_responses", _}

      Plug.Conn.send_resp(conn, 201, "made")

      assert_receive {:written, "/api/application_responses", payload}
      assert payload["status"] == 201
      assert payload["body"] == "made"
    end
  end

  describe "the per-request store" do
    test "is empty again once the response has been sent" do
      # The store is the process dictionary. Anything reusing a process for a
      # second unit of work would otherwise read the previous request's uuid.
      run(Plug.Test.conn("GET", "/books"))

      assert RequestStore.get_uuid() == nil
      assert RequestStore.get_source_env_id() == nil
    end
  end

  describe "when reporting itself fails" do
    test "reports the exception and re-raises it rather than swallowing it" do
      # A user-supplied version finder runs inside this plug. Swallowing its
      # failure would turn a host-app defect into silently missing telemetry.
      Config.update(version_finder: fn _conn -> raise "finder exploded" end)

      assert_raise RuntimeError, "finder exploded", fn ->
        ReportInteraction.call(Plug.Test.conn("GET", "/books"), [])
      end

      assert_receive {:written, "/api/application_errors", payload}
      assert payload["message"] == "finder exploded"
      assert payload["stacktrace"] != []
    end

    test "leaves nothing behind in the per-request store after a failure" do
      Config.update(version_finder: fn _conn -> raise "finder exploded" end)

      assert_raise RuntimeError, fn ->
        ReportInteraction.call(Plug.Test.conn("GET", "/books"), [])
      end

      assert RequestStore.get_uuid() == nil
    end

    test "does not report an authorization failure as an application error" do
      # An UnauthorizedError is a normal outcome of the authorize plug, not a
      # defect in the host application; reporting it would bury real errors.
      Config.update(version_finder: fn _conn -> raise EndPointBlank.UnauthorizedError end)

      assert_raise EndPointBlank.UnauthorizedError, fn ->
        ReportInteraction.call(Plug.Test.conn("GET", "/books"), [])
      end

      refute_received {:written, "/api/application_errors", _}
    end
  end

  defp drain do
    receive do
      {:written, _, _} -> drain()
    after
      0 -> :ok
    end
  end
end
