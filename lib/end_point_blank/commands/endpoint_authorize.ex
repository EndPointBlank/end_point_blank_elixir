defmodule EndPointBlank.Commands.EndpointAuthorize do
  @moduledoc """
  Sends an authorization check to the EndPointBlank API.

  Equivalent to `EndPointBlank::Commands::EndpointAuthorize` in the Ruby gem.
  """

  require Logger
  alias EndPointBlank.{Config, Authorization, RequestStore, VersionFinder}

  @doc """
  Authorizes `conn` against the EndPointBlank service.

  Returns `{:ok, conn}` on success (HTTP 201), with the
  `source_application_environment_id` stored in `RequestStore`.
  Returns `{:error, reason}` otherwise.
  """
  def authorize(%Plug.Conn{} = conn, path \\ nil, version \\ nil) do
    config = Config.get()
    path = path || conn.request_path
    version = version || VersionFinder.find(conn)
    client_auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
    target_hostname = conn.host
    auth = Authorization.header(target_hostname)

    body = %{
      path: path,
      http_method: conn.method,
      client_auth: client_auth,
      target_hostname: target_hostname,
      application: config.app_name,
      endpoint_version: version,
      source_ip: remote_ip(conn),
      uuid: RequestStore.get_uuid()
    }

    case Req.post(Config.authorize_url(), json: body, headers: [{"authorization", auth}]) do
      {:ok, %Req.Response{status: 201, body: resp_body}} ->
        source_env_id =
          case resp_body do
            %{"accesses" => [%{"source_application_environment_id" => id} | _]} -> id
            _ -> nil
          end

        RequestStore.put_source_env_id(source_env_id)
        {:ok, conn}

      {:ok, %Req.Response{status: s, body: b}} ->
        Logger.error("[EndPointBlank] Authorization failed: status=#{s} body=#{inspect(b)}")
        {:error, :unauthorized}

      {:error, reason} ->
        Logger.error("[EndPointBlank] Authorization error: #{inspect(reason)}")
        {:error, :service_unavailable}
    end
  end

  defp remote_ip(%{remote_ip: ip}) when is_tuple(ip) do
    ip |> Tuple.to_list() |> Enum.join(".")
  end

  defp remote_ip(_), do: nil
end
