defmodule EndPointBlank.Commands.EndpointUpdate do
  @moduledoc """
  Registers application endpoints with the EndPointBlank API at startup.

  Equivalent to `EndPointBlank::Commands::EndpointUpdate` in the Ruby gem.
  """

  require Logger
  alias EndPointBlank.{Config, Authorization, Http}

  @doc """
  Sends the endpoint list to the EndPointBlank API.

  Returns `:ok`, or `:error` after logging why. Never raises: this runs from
  the host application's start. When `client_id` or `client_secret` is not
  configured nothing is sent (sc-1469).
  """
  def update(endpoints) when is_list(endpoints) do
    case Authorization.intake_header() do
      {:ok, auth} ->
        send_update(endpoints, auth)

      {:error, :missing_credentials} ->
        Logger.error(
          "[EndPointBlank] Endpoint update not sent: " <>
            Authorization.missing_credentials_message()
        )

        :error
    end
  end

  defp send_update(endpoints, auth) do
    config = Config.get()

    body = %{
      application: config.app_name,
      hostname: hostname(),
      lib_version: EndPointBlank.version(),
      environment: config.environment,
      endpoints: endpoints,
      app_version: config.application_version
    }

    Logger.info(
      "[EndPointBlank] Sending application update: " <>
        "application=#{body.application} environment=#{body.environment} " <>
        "app_version=#{body.app_version}"
    )

    case Http.post(Config.endpoint_update_url(), body, auth) do
      {:ok, %Req.Response{status: s}} when s in 200..299 ->
        Logger.info("[EndPointBlank] Endpoints registered: #{s}")
        :ok

      {:ok, %Req.Response{status: s, body: b}} ->
        Logger.error("[EndPointBlank] Endpoint update failed: status=#{s} body=#{inspect(b)}")
        :error

      {:error, reason} ->
        Logger.error("[EndPointBlank] Endpoint update error: #{Http.describe_error(reason)}")
        :error
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
