defmodule EndPointBlank.Authorization do
  @moduledoc """
  Builds Authorization headers for outbound requests to the EndPointBlank API.

  Returns a Bearer token header when a valid cached token exists for the target
  hostname, otherwise falls back to HTTP Basic auth.
  """

  alias EndPointBlank.{Config, AccessTokens}

  @doc """
  Returns the best available Authorization header value for the given hostname.

  If a valid access token is cached for `hostname`, returns `"Bearer <token>"`.
  Otherwise returns `"Basic <credentials>"`.
  """
  def header(hostname \\ nil) do
    if hostname && AccessTokens.exists?(hostname) do
      token = AccessTokens.token(hostname)
      "Bearer #{token}"
    else
      basic_header()
    end
  end

  @doc "Returns an HTTP Basic `Authorization` header value."
  def basic_header, do: "Basic #{basic_credentials()}"

  @doc "Returns Base64-encoded `client_id:client_secret`."
  def basic_credentials do
    config = Config.get()
    Base.encode64("#{config.client_id}:#{config.client_secret}")
  end
end
