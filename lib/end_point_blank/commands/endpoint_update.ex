defmodule EndPointBlank.Commands.EndpointUpdate do
  @moduledoc """
  Registers application endpoints with the EndPointBlank API at startup.

  Equivalent to `EndPointBlank::Commands::EndpointUpdate` in the Ruby gem.
  """

  require Logger
  alias EndPointBlank.{Config, Authorization, Http}

  @doc "Sends the endpoint list to the EndPointBlank API."
  def update(endpoints) when is_list(endpoints) do
    config = Config.get()
    auth = Authorization.basic_header()

    body = %{
      application: config.app_name,
      hostname: hostname(),
      lib_version: EndPointBlank.version(),
      environment: config.environment,
      endpoints: endpoints,
      app_version: config.application_version
    }

    case Http.post(Config.endpoint_update_url(), body, auth) do
      {:ok, %Req.Response{status: s}} when s in 200..299 ->
        Logger.info("[EndPointBlank] Endpoints registered: #{s}")
        :ok

      {:ok, %Req.Response{status: s, body: b}} ->
        Logger.error("[EndPointBlank] Endpoint update failed: status=#{s} body=#{inspect(b)}")
        :error

      {:error, reason} ->
        Logger.error("[EndPointBlank] Endpoint update error: #{inspect(reason)}")
        :error
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
