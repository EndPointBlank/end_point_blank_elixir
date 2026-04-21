defmodule EndPointBlank.Writers.RequestWriter do
  @moduledoc "Sends inbound request metadata to the EndPointBlank API."

  alias EndPointBlank.{Config, RequestStore, VersionFinder, Writers}

  def write(%Plug.Conn{} = conn) do
    config = Config.get()

    payload = %{
      app_name: config.app_name,
      env: config.environment,
      uuid: RequestStore.get_uuid(),
      host: conn.host,
      headers: Map.new(conn.req_headers),
      path: conn.request_path,
      http_method: conn.method,
      endpoint_version: VersionFinder.find(conn),
      request: read_body(conn),
      sent_at: utc_now()
    }

    Writers.write(:requests, config.log_mode, [payload])
  end

  defp read_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> nil
      params when map_size(params) > 0 -> Jason.encode!(params) |> truncate()
      _ -> nil
    end
  end

  defp truncate(s) when byte_size(s) > 1024, do: binary_part(s, 0, 1024) <> "..."
  defp truncate(s), do: s

  defp utc_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
