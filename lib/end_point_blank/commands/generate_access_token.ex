defmodule EndPointBlank.Commands.GenerateAccessToken do
  @moduledoc """
  Requests a new access token from the EndPointBlank API.

  Two entry points, on purpose. `generate/1` is the original one and answers
  the payload or `nil`; `generate_result/1` answers an `{:ok, _} | {:error, _}`
  tuple that says *why* a mint failed. The status intake returns carries a
  decision a caller cannot otherwise make -- a rejected credential is
  permanent until someone re-issues it, an intake that fell over is not -- and
  `nil` erases it.
  """

  require Logger
  alias EndPointBlank.{Config, Authorization, Http, OutboundUrl}

  @typedoc """
  Why a mint failed.

  Permanent -- the identical call cannot succeed until something changes
  outside this process:

    * `:credential_rejected` -- intake answered 401. The `client_id` /
      `client_secret` this SDK is configured with was refused, and will go on
      being refused until the credential is re-issued.
    * `{:request_rejected, status}` -- intake answered some other 4xx. What
      was asked for cannot be granted: intake's access-token controller sends
      400 for an invalid `token_ttl` or a missing `base_url`, and 422 for a
      target or source application it does not know. The credential is fine;
      the request or the registration is not.

  Transient -- worth trying again:

    * `{:server_error, status}` -- intake is broken. A 5xx, any other
      unexpected non-2xx, or a 2xx this cannot read an access token out of --
      an undecodable body, a body that is not a JSON object, or one carrying
      no `token` or no `base_url`. The status is the real one intake sent,
      including when it was a 2xx; *why* a 2xx was unusable is in the log line
      rather than in the return value, which is where a human debugging it
      looks.
    * `{:transport_error, reason}` -- no HTTP status was obtained at all:
      connection refused, timeout, `Http.post/3`'s three attempts exhausted.
      Only a real transport failure lands here (a `Req.TransportError` or
      `Req.HTTPError`, their Mint/Finch equivalents, or an atom such as
      `:timeout`); anything else the HTTP client hands back is
      `{:unexpected, reason}`, which `generate_result/1` answers but which is
      not a `t:failure/0`.
  """
  @type failure ::
          :credential_rejected
          | {:request_rejected, pos_integer()}
          | {:server_error, pos_integer()}
          | {:transport_error, term()}

  @doc """
  Requests a new access token for `base_url`, reporting why a failure failed.

  `base_url` has its userinfo, query and fragment removed, its scheme and
  host lowercased and a default or empty port dropped
  (`EndPointBlank.OutboundUrl.strip/1`); the path is sent as written,
  unconditionally alongside `token_ttl` (which goes over the wire as an
  explicit `null` when unconfigured — intake handles that deliberately).
  intake normalizes `base_url` and matches it against registered base URLs by
  longest path prefix. `EndPointBlank.AccessTokens` strips before it gets
  here; this strips again so a direct caller cannot send intake a secret
  either.

  Returns `{:ok, payload}` -- a map carrying a non-empty `token` and
  `base_url`, plus whatever else intake sent (`expired_at`) -- or
  `{:error, reason}` where `reason` is a `t:failure/0`. See that type for
  which reasons are permanent and which are worth retrying. A `base_url` that
  is not a string, or that `OutboundUrl.strip/1` refuses (not an absolute
  `http` or `https` URL with a host, or a port outside 1..65535), answers
  `{:error, :invalid_base_url}` without a request.

  Two answers are not intake's verdict and are not a `t:failure/0`:

    * `{:error, :missing_credentials}` -- `client_id` or `client_secret` is
      nil or empty, so nothing is sent. Sending it anyway would go out as
      `Basic` of `":"` and come back as a 401 that reads as a revoked
      credential (sc-1469).
    * `{:error, {:unexpected, reason}}` -- the HTTP client answered an error
      that is not a transport failure (see `t:failure/0`): a bug or a
      bad setting, not intake being out of reach. Anything raised while
      minting propagates as itself; `EndPointBlank.AccessTokens` reports it the
      same way.
  """
  @spec generate_result(term()) ::
          {:ok, map()}
          | {:error, failure() | :invalid_base_url | :missing_credentials | {:unexpected, term()}}
  def generate_result(base_url) do
    case OutboundUrl.strip(base_url) do
      {:ok, stripped} -> request(stripped, Config.get())
      {:error, :invalid_base_url} -> {:error, :invalid_base_url}
    end
  end

  defp request(base_url, config) do
    case Authorization.intake_header() do
      {:ok, auth} ->
        send_request(base_url, config, auth)

      {:error, :missing_credentials} ->
        Logger.error(
          "[EndPointBlank] Access token not requested: " <>
            Authorization.missing_credentials_message()
        )

        {:error, :missing_credentials}
    end
  end

  defp send_request(base_url, config, auth) do
    body = %{base_url: base_url, token_ttl: config.token_ttl}

    case Http.post(Config.access_token_url(), body, auth) do
      {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
        # The one place the body gets a say, and only because there is nothing
        # else to go on: a success status this cannot read an access token out
        # of is a broken server. It still reports the real 2xx status.
        case document_problem(body) do
          nil ->
            {:ok, body}

          problem ->
            Logger.error("[EndPointBlank] GenerateAccessToken failed: status=#{s} #{problem}")
            {:error, {:server_error, s}}
        end

      # Classified on the status ALONE -- the body is not even looked at.
      #
      # Invariant: `{:transport_error, _}` means no usable HTTP status was
      # obtained. Anything with a status is classified by that status, whatever
      # shape its body turned out to be. Do not reintroduce parse-first here:
      # this SDK reaches intake through Caddy in production, and any proxy,
      # WAF, ALB or auth gateway in front of the app can answer 401 with an
      # HTML error page the app never generated. Deciding on the body would
      # read that as transient and retry a dead credential forever -- the exact
      # failure this distinction exists to remove.
      {:ok, %Req.Response{status: s}} ->
        Logger.error("[EndPointBlank] GenerateAccessToken failed: status=#{s}")
        {:error, classify(s)}

      # Only a real transport failure is a :transport_error, and the log line
      # names its atom reason or exception module, never inspect/1 of the
      # term: that can carry the request, Authorization header included.
      {:error, reason} ->
        if Http.transport_error?(reason) do
          Logger.error(
            "[EndPointBlank] GenerateAccessToken error: #{Http.describe_error(reason)}"
          )

          {:error, {:transport_error, reason}}
        else
          Logger.error(
            "[EndPointBlank] GenerateAccessToken failed unexpectedly: #{Http.describe_error(reason)}"
          )

          {:error, {:unexpected, reason}}
        end
    end
  end

  @doc """
  Requests a new access token for `base_url`.

  Returns the parsed response map (`token`, `expired_at`, `base_url`) on
  success, or `nil` on failure.

  Unchanged, deliberately: this is a published library, and callers depend on
  the payload-or-`nil` contract. It is a thin wrapper over
  `generate_result/1`, which is where a caller that needs to tell a rejected
  credential from a failed intake should go instead.
  """
  def generate(base_url) do
    case generate_result(base_url) do
      {:ok, payload} -> payload
      {:error, _reason} -> nil
    end
  end

  # 401 is singled out by intake itself: its access-token controller answers
  # 401 for an invalid or revoked credential specifically so this decision is
  # possible, and 422 -- not 401 -- for an application it cannot resolve.
  defp classify(401), do: :credential_rejected
  defp classify(status) when status in 400..499, do: {:request_rejected, status}

  # 5xx, and anything else that is neither 2xx nor 4xx. A 1xx or an unfollowed
  # 3xx is a broken server, not a rejected request, so it lands here rather
  # than falling off the end of this function.
  defp classify(status), do: {:server_error, status}

  # Returns nil if `body` is a usable token document, or a human-readable
  # description of what is wrong with it.
  #
  # Req hands back an undecodable body as a raw binary rather than raising, so
  # a non-map has to be looked for rather than waited for: `body["token"]`
  # raises for a binary or a list, and this runs inside the AccessTokens
  # GenServer. An SDK must not be able to crash the application it is embedded
  # in because intake is misconfigured.
  defp document_problem(body) when not is_map(body), do: "(body was not a JSON object)"

  defp document_problem(body) do
    cond do
      not usable_string?(Map.get(body, "token")) ->
        no_token_reason(body)

      not usable_string?(Map.get(body, "base_url")) ->
        # Distinct from a rejected request: intake's base_url is NOT NULL, and
        # it answers 422 rather than minting when the caller's URL resolves to
        # no environment. A 2xx without one is a broken server. There is also
        # nothing to cache the token under.
        "(response carried a token but no base_url)"

      true ->
        nil
    end
  end

  defp usable_string?(value), do: is_binary(value) and value != ""

  defp no_token_reason(%{"error" => error}) when is_binary(error), do: "(#{error})"

  # intake is expected to send "error" as a string. A misbehaving intake
  # sending anything else (a nested object, a number) must not crash the
  # caller either -- inspect/1, not the plain string interpolation this value
  # flows into, because String.Chars has no implementation for a map, tuple,
  # PID, function, reference, port, or a non-codepoint list.
  defp no_token_reason(%{"error" => error}), do: "(#{inspect(error)})"

  defp no_token_reason(_body), do: "(no token in response)"
end
