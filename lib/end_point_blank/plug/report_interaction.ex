defmodule EndPointBlank.Plug.ReportInteraction do
  @moduledoc """
  Plug that tracks every request/response pair.

  - Generates a per-request UUID stored in `RequestStore`.
  - Writes request metadata immediately via `RequestWriter`.
  - Registers a `before_send` callback to write response metadata.
  - On unhandled exceptions, writes to `ExceptionWriter` before re-raising.

  Place this plug early in your endpoint pipeline, before routing:

      plug EndPointBlank.Plug.ReportInteraction
  """

  import Plug.Conn
  alias EndPointBlank.{RequestStore, Writers}

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    uuid = RequestStore.generate_uuid()
    RequestStore.put_uuid(uuid)

    Writers.RequestWriter.write(conn)

    register_before_send(conn, fn conn ->
      Writers.ResponseWriter.write(conn)
      RequestStore.clear()
      conn
    end)
  rescue
    e in EndPointBlank.UnauthorizedError ->
      reraise e, __STACKTRACE__

    e ->
      Writers.ExceptionWriter.write(e, __STACKTRACE__)
      RequestStore.clear()
      reraise e, __STACKTRACE__
  end
end
