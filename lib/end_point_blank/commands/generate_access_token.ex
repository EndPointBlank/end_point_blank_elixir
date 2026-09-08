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
  alias EndPointBlank.{Config, Authorization, Http}

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

    * `{:server_error, status}` -- a 5xx (or any other unexpected non-2xx).
    * `{:transport_error, reason}` -- the call never got an answer: connection
      refused, timeout, `Http.post/3`'s three attempts exhausted.
  """
  @type failure ::
          :credential_rejected
          | {:request_rejected, pos_integer()}
          | {:server_error, pos_integer()}
          | {:transport_error, term()}

  @doc """
  Requests a new access token for `base_url`, reporting why a failure failed.

  `base_url` is sent verbatim, unconditionally alongside `token_ttl` (which
  goes over the wire as an explicit `null` when unconfigured — intake handles
  that deliberately). intake normalizes `base_url` and matches it against
  registered base URLs by longest path prefix.

  Returns `{:ok, payload}` with the parsed response map (`token`,
  `expired_at`, `base_url`) on any 2xx, or `{:error, reason}` where `reason`
  is a `t:failure/0`. See that type for which reasons are permanent and which
  are worth retrying.

  A 2xx whose body is not a usable token document is still `{:ok, payload}`
  here: this function reports the transport and the status, and leaves judging
  the document to the caller that knows what it needs from it.
  """
  @spec generate_result(term()) :: {:ok, term()} | {:error, failure()}
  def generate_result(base_url) do
    config = Config.get()
    body = %{base_url: base_url, token_ttl: config.token_ttl}
    auth = Authorization.basic_header()

    case Http.post(Config.access_token_url(), body, auth) do
      {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: s}} ->
        Logger.error("[EndPointBlank] GenerateAccessToken failed: status=#{s}")
        {:error, classify(s)}

      {:error, reason} ->
        Logger.error("[EndPointBlank] GenerateAccessToken error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}
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
end
