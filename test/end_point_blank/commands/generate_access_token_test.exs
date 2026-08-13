defmodule EndPointBlank.Commands.GenerateAccessTokenTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.Config
  alias EndPointBlank.Commands.GenerateAccessToken

  setup do
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(client_id: "cid", client_secret: "csecret", base_url: "https://intake.test")

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
        {:token_request, conn.request_path, Jason.decode!(raw),
         conn |> Plug.Conn.get_req_header("authorization") |> List.first()}
      )

      fun.(conn)
    end)
  end

  test "returns the token document intake issued" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => "abc", "expired_at" => "2030-01-01T00:00:00Z"})
    end)

    assert GenerateAccessToken.generate("https://api.example.com/orders") == %{
             "token" => "abc",
             "expired_at" => "2030-01-01T00:00:00Z"
           }
  end

  test "asks the access-token endpoint for the given base_url and configured TTL" do
    Config.update(token_ttl: 1_800)
    stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "abc"}) end)

    GenerateAccessToken.generate("https://api.example.com/orders")

    assert_receive {:token_request, path, body, _auth}
    assert path == "/api/access_token"
    assert body == %{"base_url" => "https://api.example.com/orders", "token_ttl" => 1_800}
  end

  test "sends the base_url verbatim, with no normalization" do
    # Intake owns normalization and matches by longest path prefix. The SDK
    # altering the argument -- downcasing, trimming a trailing slash, or
    # reducing it to a hostname -- would change which environment the caller
    # asked for.
    messy = "https://API.Example.com:8443/Orders/"
    stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "abc"}) end)

    GenerateAccessToken.generate(messy)

    assert_receive {:token_request, _path, body, _auth}
    assert body["base_url"] == messy
  end

  test "authenticates with Basic credentials" do
    # A token request cannot present a token, so this must never try to.
    stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "abc"}) end)

    GenerateAccessToken.generate("https://api.example.com/orders")

    assert_receive {:token_request, _path, _body, auth}
    assert auth == "Basic " <> Base.encode64("cid:csecret")
  end

  test "returns nil and logs when intake refuses" do
    stub(fn conn -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "nope"}) end)

    log =
      capture_log(fn ->
        assert GenerateAccessToken.generate("https://api.example.com/orders") == nil
      end)

    assert log =~ "GenerateAccessToken failed"
    assert log =~ "403"
  end

  test "returns nil and logs when intake cannot be reached" do
    stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    log =
      capture_log(fn ->
        assert GenerateAccessToken.generate("https://api.example.com/orders") == nil
      end)

    assert log =~ "GenerateAccessToken error"
  end
end
