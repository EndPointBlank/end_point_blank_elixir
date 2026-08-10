defmodule EndPointBlank.Commands.EndpointUpdateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.Config
  alias EndPointBlank.Commands.EndpointUpdate

  @endpoints [%{path: "/books", http_method: "GET", endpoint_versions: ["v1"]}]

  setup do
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})

    Config.update(
      app_name: "test-app",
      environment: "test",
      application_version: "abc1234",
      client_id: "cid",
      client_secret: "csecret",
      base_url: "https://intake.test"
    )

    on_exit(fn ->
      Config.reset()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
    end)

    :ok
  end

  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:update, conn.request_path, Jason.decode!(raw),
         conn |> Plug.Conn.get_req_header("authorization") |> List.first()}
      )

      fun.(conn)
    end)
  end

  defp accepting, do: fn conn -> Req.Test.json(conn, %{"ok" => true}) end

  describe "the manifest it sends" do
    setup do
      stub(accepting())
      capture_log(fn -> EndpointUpdate.update(@endpoints) end)
      assert_receive {:update, path, body, auth}
      %{path: path, body: body, auth: auth}
    end

    test "goes to the application-updates endpoint", %{path: path} do
      assert path == "/api/application_updates"
    end

    test "identifies the application, environment and deployed version", %{body: body} do
      assert body["application"] == "test-app"
      assert body["environment"] == "test"
      assert body["app_version"] == "abc1234"
    end

    test "carries the endpoint list unchanged", %{body: body} do
      assert body["endpoints"] == [
               %{"path" => "/books", "http_method" => "GET", "endpoint_versions" => ["v1"]}
             ]
    end

    test "reports the machine it is running on", %{body: body} do
      {:ok, expected} = :inet.gethostname()
      assert body["hostname"] == to_string(expected)
    end

    test "reports the SDK version the process is actually running", %{body: body} do
      # Intake uses this to tell which client build produced a manifest, so it
      # must track the library rather than being a literal typed in twice.
      #
      # Compared against mix.exs rather than against EndPointBlank.version():
      # asserting the payload equals the same value it is built from passed
      # happily while both named 0.3.2, a version that was never released.
      assert body["lib_version"] == Mix.Project.config()[:version]
    end

    test "authenticates with Basic credentials", %{auth: auth} do
      # Registration happens at boot, before any token could have been minted.
      assert auth == "Basic " <> Base.encode64("cid:csecret")
    end
  end

  describe "outcomes" do
    test "returns :ok when intake accepts the manifest" do
      stub(accepting())

      capture_log(fn -> assert EndpointUpdate.update(@endpoints) == :ok end)
    end

    test "returns :error and logs when intake rejects the manifest" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "bad manifest"})
      end)

      log = capture_log(fn -> assert EndpointUpdate.update(@endpoints) == :error end)

      assert log =~ "Endpoint update failed"
      assert log =~ "422"
    end

    test "returns :error rather than crashing boot when intake is unreachable" do
      # This runs from the host application's start/2; raising here would stop
      # the application from booting at all.
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log = capture_log(fn -> assert EndpointUpdate.update(@endpoints) == :error end)

      assert log =~ "Endpoint update error"
    end

    test "still reports an empty endpoint list" do
      # An app that registers nothing must say so; silence is indistinguishable
      # from a client that never started.
      stub(accepting())

      capture_log(fn -> assert EndpointUpdate.update([]) == :ok end)

      assert_receive {:update, _path, body, _auth}
      assert body["endpoints"] == []
    end
  end
end
