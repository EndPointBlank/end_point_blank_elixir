defmodule EndPointBlank.Commands.GenerateAccessToken do
  @moduledoc "Requests a new access token from the EndPointBlank API."

  require Logger
  alias EndPointBlank.{Config, Authorization, Http}

  def generate(hostname) do
    config = Config.get()
    body = %{hostname: hostname, token_ttl: config.token_ttl}
    auth = Authorization.basic_header()

    case Http.post(Config.access_token_url(), body, auth) do
      {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
        body

      {:ok, %Req.Response{status: s}} ->
        Logger.error("[EndPointBlank] GenerateAccessToken failed: status=#{s}")
        nil

      {:error, reason} ->
        Logger.error("[EndPointBlank] GenerateAccessToken error: #{inspect(reason)}")
        nil
    end
  end
end
