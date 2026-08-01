defmodule EndPointBlank.Phoenix.EndpointRegistrarTest do
  @moduledoc """
  Builds the endpoint manifest sent at boot. Everything the portal knows about
  an application's surface comes from this list, so a route dropped here is an
  endpoint that simply does not exist as far as the product is concerned.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.Config
  alias EndPointBlank.Phoenix.EndpointRegistrar

  defmodule BooksController do
    use EndPointBlank.Phoenix.Versioned

    version_of(:index, ["v1", "v2"])
    version_of(:show, ["v1"])
  end

  defmodule PlainController do
    def index(_conn, _params), do: :ok
  end

  defmodule Router do
    def __routes__ do
      [
        %{verb: :get, path: "/books", plug: BooksController, plug_opts: :index},
        %{verb: :get, path: "/books/:id", plug: BooksController, plug_opts: :show},
        # Declared on the controller but not for this action.
        %{verb: :post, path: "/books", plug: BooksController, plug_opts: :create},
        # No version metadata at all.
        %{verb: :get, path: "/health", plug: PlainController, plug_opts: :index},
        # Phoenix emits duplicate entries for some route macros.
        %{verb: :get, path: "/books", plug: BooksController, plug_opts: :index}
      ]
    end
  end

  defmodule MissingControllerRouter do
    def __routes__ do
      [%{verb: :get, path: "/gone", plug: :"Elixir.NoSuchController", plug_opts: :index}]
    end
  end

  defmodule BrokenController do
    def __epb_versions__, do: raise("metadata exploded")
  end

  defmodule BrokenControllerRouter do
    def __routes__ do
      [%{verb: :get, path: "/broken", plug: BrokenController, plug_opts: :index}]
    end
  end

  setup do
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(app_name: "test-app", base_url: "https://intake.test")

    test_pid = self()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:manifest, Jason.decode!(raw)["endpoints"]})
      Req.Test.json(conn, %{"ok" => true})
    end)

    on_exit(fn ->
      Config.reset()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
    end)

    :ok
  end

  defp register(router) do
    capture_log(fn -> EndpointRegistrar.register(router) end)
    assert_receive {:manifest, endpoints}
    endpoints
  end

  test "reports each versioned route with its method and versions" do
    endpoints = register(Router)

    assert %{"path" => "/books", "http_method" => "GET", "endpoint_versions" => ["v1", "v2"]} in endpoints

    assert %{"path" => "/books/:id", "http_method" => "GET", "endpoint_versions" => ["v1"]} in endpoints
  end

  test "uppercases the HTTP method" do
    assert Enum.all?(register(Router), &(&1["http_method"] == String.upcase(&1["http_method"])))
  end

  test "omits actions with no declared versions" do
    # An action the developer has not declared is not an endpoint the portal
    # should start charging for or alerting on.
    paths = Enum.map(register(Router), & &1["path"])

    refute "/health" in paths
  end

  test "omits an action on a versioned controller that has no versions of its own" do
    endpoints = register(Router)

    refute Enum.any?(endpoints, &(&1["path"] == "/books" and &1["http_method"] == "POST"))
  end

  test "reports a duplicated route once" do
    endpoints = register(Router)

    assert Enum.count(endpoints, &(&1["path"] == "/books" and &1["http_method"] == "GET")) == 1
  end

  test "skips a route whose controller cannot be loaded rather than failing boot" do
    # Registration runs from the host application's start/2. A stale route
    # pointing at a deleted module must not stop the app from booting.
    assert register(MissingControllerRouter) == []
  end

  test "skips a controller whose version metadata raises rather than failing boot" do
    assert register(BrokenControllerRouter) == []
  end
end
