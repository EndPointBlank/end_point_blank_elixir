defmodule EndPointBlank.Plug.AuthorizedTest do
  @moduledoc """
  The plug is the only thing standing between an unauthorized caller and the
  controller behind it, so what matters here is that a refusal halts the
  pipeline — a response body alone does not stop the controller from running.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.{AccessTokens, Config, RequestStore}
  alias EndPointBlank.Plug.Authorized

  defmodule Router do
    def __routes__ do
      [%{verb: :get, path: "/books/:id", plug: BooksController, plug_opts: :show}]
    end
  end

  setup do
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})

    Config.update(
      app_name: "test-app",
      client_id: "cid",
      client_secret: "csecret",
      base_url: "https://intake.test"
    )

    on_exit(fn ->
      Config.reset()
      RequestStore.clear()
      AccessTokens.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
    end)

    %{path: "/books/#{System.unique_integer([:positive])}"}
  end

  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:authorize, Jason.decode!(raw)})
      fun.(conn)
    end)
  end

  defp granting(deprecation \\ nil) do
    body =
      %{"accesses" => [%{"source_application_environment_id" => "app-env-1"}]}
      |> then(fn b -> if deprecation, do: Map.put(b, "deprecation", deprecation), else: b end)

    fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(body) end
  end

  defp call(ctx, opts \\ []) do
    conn = Plug.Test.conn("GET", Keyword.get(opts, :path, ctx.path))

    conn =
      case Keyword.get(opts, :router) do
        nil -> conn
        router -> Plug.Conn.put_private(conn, :phoenix_router, router)
      end

    Authorized.call(conn, Authorized.init([]))
  end

  describe "when the caller is authorized" do
    test "lets the request continue to the controller", ctx do
      stub(granting())

      conn = call(ctx)

      refute conn.halted
      assert conn.status == nil
    end

    test "sets the deprecation headers the authorization came with", ctx do
      stub(granting(%{"deprecated_at" => "2026-01-01T00:00:00Z"}))

      conn = call(ctx)

      assert Plug.Conn.get_resp_header(conn, "deprecation") == ["@1767225600"]
    end
  end

  describe "the path it authorizes" do
    test "is the route pattern when a Phoenix router is on the conn", ctx do
      # Intake matches on the registered pattern; sending `/books/17` would look
      # like an endpoint nobody registered.
      stub(granting())

      call(ctx, router: Router)

      assert_receive {:authorize, body}
      assert body["path"] == "/books/:id"
    end

    test "is the literal request path outside Phoenix", ctx do
      stub(granting())

      call(ctx)

      assert_receive {:authorize, body}
      assert body["path"] == ctx.path
    end
  end

  describe "when the caller is refused" do
    test "halts the pipeline so the controller never runs", ctx do
      stub(fn conn -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "no"}) end)

      conn = capture_log_result(fn -> call(ctx) end)

      assert conn.halted
      assert conn.status == 403
    end

    test "relays intake's own status and body as JSON", ctx do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid token"})
      end)

      conn = capture_log_result(fn -> call(ctx) end)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid token"}

      assert Plug.Conn.get_resp_header(conn, "content-type") == [
               "application/json; charset=utf-8"
             ]
    end

    test "passes a non-JSON body through without re-encoding it", ctx do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(403, "forbidden")
      end)

      conn = capture_log_result(fn -> call(ctx) end)

      assert conn.status == 403
      assert conn.resp_body == "forbidden"
    end
  end

  describe "when the authorization service is unavailable" do
    test "fails closed with a 503 rather than letting the request through", ctx do
      # Failing open here would silently disable authorization for every request
      # for as long as intake is down.
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      conn = capture_log_result(fn -> call(ctx) end)

      assert conn.halted
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "Authorization service unavailable"}
    end
  end

  # Runs `fun` with its log suppressed and returns its value.
  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)
    assert_receive {:result, result}
    result
  end
end
