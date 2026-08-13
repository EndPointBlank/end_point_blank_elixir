defmodule EndPointBlank.Commands.GenerateAccessToken do
  @moduledoc "Requests a new access token from the EndPointBlank API."

  require Logger
  alias EndPointBlank.{Config, Authorization, Http}

  @doc """
  Requests a new access token for `base_url`.

  `base_url` is sent verbatim, unconditionally alongside `token_ttl` (which
  goes over the wire as an explicit `null` when unconfigured — intake handles
  that deliberately). intake normalizes `base_url` and matches it against
  registered base URLs by longest path prefix.

  Returns the parsed response map (`token`, `expired_at`, `base_url`) on
  success, or `nil` on failure.
  """
  def generate(base_url) do
    config = Config.get()
    body = %{base_url: base_url, token_ttl: config.token_ttl}
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
