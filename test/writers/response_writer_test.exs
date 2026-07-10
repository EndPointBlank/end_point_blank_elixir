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
end
