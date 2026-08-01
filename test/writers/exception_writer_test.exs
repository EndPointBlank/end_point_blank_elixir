defmodule EndPointBlank.Writers.ExceptionWriterTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.{Config, RequestStore}
  alias EndPointBlank.Writers.ExceptionWriter

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

  defp raised do
    raise ArgumentError, "something broke"
  rescue
    e -> {e, __STACKTRACE__}
  end

  test "posts to the application-errors endpoint" do
    {error, trace} = raised()
    ExceptionWriter.write(error, trace)

    assert written().path == "/api/application_errors"
  end

  test "sends the exception's human-readable message" do
    {error, trace} = raised()
    ExceptionWriter.write(error, trace)

    assert written().payload["message"] == "something broke"
  end

  test "sends the stacktrace as an array of formatted frames" do
    # Intake stores frames as a list. A single joined string would render as one
    # unreadable line in the portal.
    {error, trace} = raised()
    ExceptionWriter.write(error, trace)

    frames = written().payload["stacktrace"]

    assert is_list(frames)
    assert length(frames) > 1
    assert Enum.all?(frames, &is_binary/1)
  end

  test "sends an empty stacktrace when none was captured" do
    ExceptionWriter.write(%RuntimeError{message: "bare"})

    assert written().payload["stacktrace"] == []
  end

  test "ties the error to the request it happened during" do
    RequestStore.put_uuid("uuid-1")
    RequestStore.put_source_env_id("app-env-1")

    {error, trace} = raised()
    ExceptionWriter.write(error, trace)

    %{payload: payload} = written()
    assert payload["uuid"] == "uuid-1"
    assert payload["source_application_environment_id"] == "app-env-1"
  end

  test "stamps the path and method when a conn is in scope" do
    RequestStore.put_conn(Plug.Test.conn("DELETE", "/books/1"))

    ExceptionWriter.write(%RuntimeError{message: "bare"})

    %{payload: payload} = written()
    assert payload["stamped_path"] == "/books/1"
    assert payload["stamped_http_method"] == "DELETE"
  end

  test "masks the message when a rule targets it" do
    # Exception messages routinely interpolate the value that caused them.
    Config.update(
      masking_rules: [
        %{target: "error_message", path: nil, regex: "\\d{4,}", replacement_value: "[redacted]"}
      ]
    )

    ExceptionWriter.write(%RuntimeError{message: "card 4111111111111111 rejected"})

    assert written().payload["message"] == "card [redacted] rejected"
  end
end
