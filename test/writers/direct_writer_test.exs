defmodule EndPointBlank.Writers.DirectWriterTest do
  @moduledoc """
  The writer that actually puts telemetry on the wire. Its one hard rule is that
  a failure must never escape: these calls happen inside the host application's
  request path, and a raised exception here would turn a telemetry outage into
  the host's outage.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.{Config, Writers}
  alias EndPointBlank.Writers.DirectWriter

  setup do
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})

    Config.update(
      client_id: "cid",
      client_secret: "csecret",
      log_base_url: "https://log.test",
      base_url: "https://intake.test"
    )

    on_exit(fn ->
      Config.reset()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
    end)

    :ok
  end

  defp stub(fun \\ &Req.Test.json(&1, %{"ok" => true})) do
    test_pid = self()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:posted, conn.request_path, Jason.decode!(raw),
         conn |> Plug.Conn.get_req_header("authorization") |> List.first()}
      )

      fun.(conn)
    end)
  end

  describe "routing" do
    for {key, path} <- [
          requests: "/api/application_requests",
          responses: "/api/application_responses",
          logs: "/api/application_logs",
          errors: "/api/application_errors"
        ] do
      test "#{key} go to #{path}" do
        stub()

        DirectWriter.write(unquote(key), [%{a: 1}])

        assert_receive {:posted, unquote(path), _body, _auth}
      end
    end

    test "an unrecognised key falls back to the errors endpoint rather than crashing" do
      stub()

      DirectWriter.write(:not_a_real_key, [%{a: 1}])

      assert_receive {:posted, "/api/application_errors", _body, _auth}
    end
  end

  test "wraps the batch under a payload key" do
    stub()

    DirectWriter.write(:logs, [%{"a" => 1}, %{"b" => 2}])

    assert_receive {:posted, _path, body, _auth}
    assert body == %{"payload" => [%{"a" => 1}, %{"b" => 2}]}
  end

  test "authenticates with Basic credentials when no token is cached" do
    stub()

    DirectWriter.write(:logs, [%{a: 1}])

    assert_receive {:posted, _path, _body, auth}
    assert auth == "Basic " <> Base.encode64("cid:csecret")
  end

  describe "outcomes" do
    test "returns :ok when intake accepts the batch" do
      stub()

      assert DirectWriter.write(:logs, [%{a: 1}]) == :ok
    end

    test "returns :error and logs when intake rejects the batch" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "bad payload"})
      end)

      log = capture_log(fn -> assert DirectWriter.write(:logs, [%{a: 1}]) == :error end)

      assert log =~ "Write to logs failed"
      assert log =~ "422"
    end

    test "returns :error rather than raising when intake is unreachable" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log = capture_log(fn -> assert DirectWriter.write(:logs, [%{a: 1}]) == :error end)

      assert log =~ "Write to logs error"
    end
  end

  describe "Writers.write/3 dispatch" do
    setup do
      # The delayed path writes from tasks spawned by the DelayedWriter process,
      # so the stub has to be visible process-wide.
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      :ok
    end

    test "sends straight to the network in :direct mode" do
      stub()

      Writers.write(:logs, :direct, [%{a: 1}])

      assert_receive {:posted, "/api/application_logs", _body, _auth}
    end

    test "queues in :delayed mode and sends on the next flush" do
      # The point of :delayed is that the caller's request is not held open for
      # the network round trip.
      stub()
      writer = Process.whereis(EndPointBlank.Writers.DelayedWriter)

      Writers.write(:logs, :delayed, [%{a: 1}])
      :sys.get_state(writer)

      refute_received {:posted, _path, _body, _auth}

      send(writer, :flush)
      # handle_info(:flush, ...) does not reply until every write task is done.
      :sys.get_state(writer)

      assert_receive {:posted, "/api/application_logs", _body, _auth}
    end
  end
end
