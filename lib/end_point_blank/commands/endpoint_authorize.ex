defmodule EndPointBlank.Commands.EndpointAuthorize do
  @moduledoc """
  Sends an authorization check to the EndPointBlank API.

  Equivalent to `EndPointBlank::Commands::EndpointAuthorize` in the Ruby gem.
  """

  require Logger

  alias EndPointBlank.{
    AccessTokens,
    AuthCache,
    Config,
    Authorization,
    DeprecationHeaders,
    Http,
    RequestStore,
    VersionFinder
  }

  @doc """
  Authorizes `conn` against the EndPointBlank service.

  Successful results are cached in `AuthCache` keyed on
  `(client_auth, path, method, app_name)`. Cache hits skip the network
  call entirely and return immediately.

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

    # The version is part of the key because authorization is decided per
    # endpoint version, and so is the deprecation carried back with it. Without
    # it, two callers on different versions of the same route share one entry.
    cache_key = "epb_auth:#{client_auth}:#{path}:#{conn.method}:#{config.app_name}:#{version}"

    case AuthCache.get(cache_key) do
      {:hit, {source_env_id, deprecation}} ->
        # The cache carries the deprecation as well as the env id. Authorization
        # is cached per client+route, so caching only the env id would limit the
        # Deprecation and Sunset headers to cache misses — roughly one request
        # in N, which reads as a flaky feature rather than a missing one.
        RequestStore.put_source_env_id(source_env_id)
        {:ok, DeprecationHeaders.put_headers(conn, deprecation)}

      {:hit, source_env_id} ->
        # An entry cached before this release, holding only the env id.
        RequestStore.put_source_env_id(source_env_id)
        {:ok, conn}

      :miss ->
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

        result = Http.post(Config.authorize_url(), body, auth)

        result =
          case result do
            {:ok, %Req.Response{status: 401}} ->
              if String.starts_with?(auth, "Bearer ") do
                AccessTokens.remove(target_hostname)

                retry_auth =
                  case AccessTokens.token(target_hostname) do
                    nil -> Authorization.basic_header()
                    fresh -> "Bearer #{fresh}"
                  end

                Http.post(Config.authorize_url(), body, retry_auth)
              else
                result
              end

            _ ->
              result
          end

        case result do
          {:ok, %Req.Response{status: 201, body: resp_body}} ->
            source_env_id =
              case resp_body do
                %{"accesses" => [%{"source_application_environment_id" => id} | _]} -> id
                _ -> nil
              end

            deprecation =
              case resp_body do
                %{"deprecation" => %{} = block} -> block
                _ -> nil
              end

            AuthCache.put(cache_key, {source_env_id, deprecation})
            RequestStore.put_source_env_id(source_env_id)
            {:ok, DeprecationHeaders.put_headers(conn, deprecation)}

          {:ok, %Req.Response{status: s, body: b}} ->
            Logger.error("[EndPointBlank] Authorization failed: status=#{s} body=#{inspect(b)}")
            {:error, s, b}

          {:error, reason} ->
            Logger.error("[EndPointBlank] Authorization error: #{inspect(reason)}")
            {:error, :service_unavailable}
        end
    end
  end

  defp remote_ip(%{remote_ip: ip}) when is_tuple(ip) do
    ip |> Tuple.to_list() |> Enum.join(".")
  end

  defp remote_ip(_), do: nil
end
