defmodule EndPointBlank.Authorization do
  @moduledoc """
  Builds `Authorization` header values.

  Two audiences, kept apart on purpose (sc-1469):

    * **Outbound calls to a provider** -- another service protected by
      EndPointBlank -- use `header/1` or `header!/1`. They only ever produce a
      `Bearer` access token. When no token can be obtained they refuse, with
      `{:error, reason}` or `EndPointBlank.TokenUnavailableError`, and the call
      must not be made. They never fall back to this service's own
      `client_id`/`client_secret`: a provider is not EndPointBlank and must
      never be handed the credential.
    * **Calls to this SDK's own intake** -- authorize, token minting, endpoint
      updates and the log/request/response/error writers -- use
      `basic_header/0`. intake already holds this service's credential, so
      presenting it there reveals nothing.

  There is deliberately no no-argument `header/0`. It used to answer Basic, and
  so did `header/1` whenever a mint failed, which handed the credential to
  whichever provider was being called during every intake outage, timeout or
  revoked credential.
  """

  alias EndPointBlank.{
    AccessTokens,
    Config,
    ConfigurationError,
    OutboundUrl,
    TokenUnavailableError
  }

  @typedoc """
  Why no `Bearer` header could be produced for an outbound call.

    * `:missing_base_url` -- the URL passed was not a non-empty string, so
      there is nothing to mint a token for.
    * `:invalid_base_url` -- the URL is not an absolute `http` or `https` URL
      with a host and, if one is written, a port from 1 to 65535 (see
      `EndPointBlank.OutboundUrl.strip/1`). Refused locally: nothing is sent
      to intake.
    * `:token_cache_unavailable` -- `EndPointBlank.AccessTokens` did not
      answer: it was not running, or a mint against a hung intake outlasted
      the call.
    * `:invalid_token` -- the cache answered `{:ok, _}` with something that is
      not a non-empty token string. `EndPointBlank.AccessTokens` guarantees it
      does not, so this is a defensive refusal for a broken guarantee rather
      than an outcome to plan for; treat it as transient.
    * `:missing_credentials` -- `client_id` or `client_secret` is not
      configured (nil or empty). Nothing is sent and retrying cannot help:
      configure both. `header!/1` raises `EndPointBlank.ConfigurationError`
      for it, not `EndPointBlank.TokenUnavailableError`.
    * `{:unexpected, reason}` -- the mint raised, threw, or the HTTP client
      answered something that is not a transport failure: a bug or a bad
      setting, not intake being out of reach. `reason` is what was raised,
      `{kind, term}` for a throw or exit, or the client's error term. The
      Ruby SDK's `TokenUnavailableError#unexpected?` marks the same case.
    * Any `t:EndPointBlank.AccessTokens.failure/0` -- the mint itself failed.
      `:credential_rejected` (intake answered 401) and
      `{:request_rejected, status}` are permanent; `{:server_error, status}`
      and `{:transport_error, reason}` (including a timeout) are transient.
  """
  @type reason ::
          :missing_base_url
          | :invalid_base_url
          | :token_cache_unavailable
          | :invalid_token
          | :missing_credentials
          | {:unexpected, term()}
          | AccessTokens.failure()

  @doc """
  Returns a `Bearer` `Authorization` header value for an outbound call to a
  provider, or says why there is none.

  `base_url` is the URL you are about to call. Its userinfo, query and
  fragment are removed before the token request (see
  `EndPointBlank.OutboundUrl.strip/1`); they are never sent to intake, logged,
  or kept on the error. A token is minted if no usable one covers it yet:
  nothing else mints the first token, so asking for one here, rather than
  first checking whether one exists, is what makes the Bearer path reachable.

  Returns `{:ok, "Bearer <token>"}`, or `{:error, reason}` (see `t:reason/0`)
  when no token could be obtained -- `:missing_credentials` when `client_id`
  or `client_secret` is not configured, without a request. Never raises, and
  never returns HTTP Basic: on an error, do not make the call.
  `TokenUnavailableError.message/2` turns a reason into a human-readable
  explanation; `header!/1` raises one.
  """
  @spec header(term()) :: {:ok, String.t()} | {:error, reason()}
  def header(base_url) when is_binary(base_url) and base_url != "" do
    with {:ok, stripped} <- OutboundUrl.strip(base_url) do
      case AccessTokens.token_result(stripped) do
        {:ok, token} when is_binary(token) and token != "" -> {:ok, "Bearer #{token}"}
        # Unreachable while AccessTokens keeps its guarantee; refuse rather
        # than raise a CaseClauseError if it ever breaks.
        {:ok, _unusable} -> {:error, :invalid_token}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def header(_base_url), do: {:error, :missing_base_url}

  @doc """
  Like `header/1`, but returns the `Bearer` header value itself and raises
  when there is none:

    * `EndPointBlank.ConfigurationError` when `client_id` or `client_secret`
      is not configured (`:missing_credentials`); nothing is sent.
    * `EndPointBlank.TokenUnavailableError` for every other reason, including
      a missing or unparseable URL (the Ruby SDK raises `ArgumentError` for
      those) and a mint that failed unexpectedly (its `:unexpected` is
      `true`). The exception's `:base_url` is the stripped URL, never the one
      passed in.

  Never returns HTTP Basic.
  """
  @spec header!(term()) :: String.t()
  def header!(base_url) do
    case header(base_url) do
      {:ok, value} -> value
      {:error, :missing_credentials} -> raise ConfigurationError
      {:error, reason} -> raise TokenUnavailableError, base_url: base_url, reason: reason
    end
  end

  @doc """
  Returns an HTTP Basic `Authorization` header value built from this service's
  own `client_id`/`client_secret`.

  **Only for calls to this SDK's own intake** (the configured `:base_url` and
  `:log_base_url`). Never use it for a call to a provider: use `header/1`,
  which refuses rather than sending the credential.
  """
  def basic_header, do: "Basic #{basic_credentials()}"

  @doc "Returns Base64-encoded `client_id:client_secret`. See `basic_header/0`."
  def basic_credentials do
    config = Config.get()
    Base.encode64("#{config.client_id}:#{config.client_secret}")
  end
end
