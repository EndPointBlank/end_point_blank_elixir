defmodule EndPointBlank.Authorization do
  @moduledoc """
  Builds Authorization headers for outbound requests to the EndPointBlank API.

  Returns a Bearer token header when a token can be obtained for the target
  hostname, otherwise falls back to HTTP Basic auth.
  """

  alias EndPointBlank.{Config, AccessTokens}

  @doc """
  Returns the best available Authorization header value for the given hostname.

  Returns `"Bearer <token>"` when a token can be obtained — minting one if this
  node is not holding one yet — and `"Basic <credentials>"` otherwise.

  Asking for the token rather than first checking whether one exists is what
  makes the Bearer path reachable at all. Nothing else mints the first token, so
  gating on `AccessTokens.exists?/0` left every call authenticating with the
  long-lived client credentials for the life of the node.

  Callers with no target hostname — the log writers — get Basic, and so does
  `GenerateAccessToken`, which uses `basic_header/0` directly and must not
  present a Bearer to the endpoint that issues them.
  """
  def header(hostname \\ nil)

  def header(hostname) when is_binary(hostname) and hostname != "" do
    case AccessTokens.token(hostname) do
      token when is_binary(token) and token != "" -> "Bearer #{token}"
      _ -> basic_header()
    end
  end

  def header(_hostname), do: basic_header()

  @doc "Returns an HTTP Basic `Authorization` header value."
  def basic_header, do: "Basic #{basic_credentials()}"

  @doc "Returns Base64-encoded `client_id:client_secret`."
  def basic_credentials do
    config = Config.get()
    Base.encode64("#{config.client_id}:#{config.client_secret}")
  end
end
