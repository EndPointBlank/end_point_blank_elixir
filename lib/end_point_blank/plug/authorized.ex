defmodule EndPointBlank.Plug.Authorized do
  @moduledoc """
  Plug that enforces EndPointBlank authorization on a controller or pipeline.

  Calls the EndPointBlank `/api/authorize` endpoint with the current request
  details. Returns a 401 JSON response if authorization fails.

  ## Usage — controller plug

      defmodule MyAppWeb.BooksController do
        use Phoenix.Controller
        plug EndPointBlank.Plug.Authorized
        ...
      end

  ## Usage — router pipeline

      pipeline :api do
        plug :accepts, ["json"]
        plug EndPointBlank.Plug.Authorized
      end
  """

  import Plug.Conn
  alias EndPointBlank.{Commands.EndpointAuthorize, Phoenix.RoutePatternFinder}

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    router = conn.private[:phoenix_router]
    path = if router, do: RoutePatternFinder.find(conn, router), else: conn.request_path
    version = EndPointBlank.VersionFinder.find(conn)

    case EndpointAuthorize.authorize(conn, path, version) do
      {:ok, conn} ->
        conn

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
        |> halt()
    end
  end
end
