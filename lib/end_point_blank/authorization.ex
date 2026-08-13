defmodule EndPointBlank.Authorization do
  @moduledoc """
  Builds Authorization headers for outbound requests to the EndPointBlank API.

  Returns a Bearer token header when a token can be obtained for the target
  base URL, otherwise falls back to HTTP Basic auth.
  """

  alias EndPointBlank.{Config, AccessTokens}

  @doc """
  Returns the best available Authorization header value for the given base URL.

  `base_url` is the URL you are about to call, with any query string and
  fragment removed. Returns `"Bearer <token>"` when a token can be obtained
  for it — minting one if no usable entry covers it yet — and
  `"Basic <credentials>"` otherwise.

  Asking for the token rather than first checking whether one exists is what
  makes the Bearer path reachable at all. Nothing else mints the first token, so
  gating on `AccessTokens.exists?/1` left every call authenticating with the
  long-lived client credentials for the life of the node.

  Callers with no target base URL — the log writers, and every call this SDK
  itself makes to intake — get Basic, and so does `GenerateAccessToken`, which
  uses `basic_header/0` directly and must not present a Bearer to the endpoint
  that issues them.
  """
  def header(base_url \\ nil)

  def header(base_url) when is_binary(base_url) and base_url != "" do
    case AccessTokens.token(base_url) do
      token when is_binary(token) and token != "" -> "Bearer #{token}"
      _ -> basic_header()
    end
  end

  def header(_base_url), do: basic_header()

  @doc "Returns an HTTP Basic `Authorization` header value."
  def basic_header, do: "Basic #{basic_credentials()}"

  @doc "Returns Base64-encoded `client_id:client_secret`."
  def basic_credentials do
    config = Config.get()
    Base.encode64("#{config.client_id}:#{config.client_secret}")
  end
end
