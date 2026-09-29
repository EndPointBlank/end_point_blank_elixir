defmodule EndPointBlank.TokenUnavailableError do
  @moduledoc """
  Raised by `EndPointBlank.Authorization.header!/1` when no access token could
  be obtained for an outbound call to a provider (sc-1469).

  Until sc-1469 the SDK fell back to HTTP Basic `client_id:client_secret`
  here, which handed this service's own credential to whichever provider it
  was calling -- during every intake outage, timeout or revoked credential.
  It now refuses instead. Do not rescue this and send Basic yourself: the
  provider is not EndPointBlank and must never see the credential.

  Fields:

    * `:base_url` -- the URL a token was requested for.
    * `:reason` -- a `t:EndPointBlank.Authorization.reason/0`. Branch on it to
      decide whether to retry: `{:transport_error, _}`, `{:server_error, _}`
      and `:token_cache_unavailable` may clear on their own;
      `:credential_rejected` and `{:request_rejected, _}` will not.
    * `:message` -- says what failed, why, and that credentials are never
      sent to providers.
  """

  @credentials_never_sent "EndPointBlank never sends this service's client_id/client_secret " <>
                            "to a provider, so there is no Basic-auth fallback and the call " <>
                            "must not be made without a token."

  defexception [:base_url, :reason, :message]

  @impl true
  def exception(opts) when is_list(opts) do
    base_url = Keyword.get(opts, :base_url)
    reason = Keyword.get(opts, :reason)

    %__MODULE__{
      base_url: base_url,
      reason: reason,
      message: Keyword.get_lazy(opts, :message, fn -> message(base_url, reason) end)
    }
  end

  @doc """
  The explanation carried by an exception for `base_url` and `reason`, for a
  caller that used the non-raising `EndPointBlank.Authorization.header/1` and
  wants the same wording in its own log line or error.
  """
  @spec message(term(), term()) :: String.t()
  def message(base_url, reason) do
    "Could not mint an EndPointBlank access token for #{inspect(base_url)}: " <>
      "#{describe(reason)}. #{@credentials_never_sent}"
  end

  defp describe(:missing_base_url) do
    "no URL was given to mint a token for (pass the URL you are about to call)"
  end

  defp describe(:token_cache_unavailable) do
    "the access-token cache did not answer in time (EndPointBlank may be slow or down)"
  end

  defp describe(:credential_rejected) do
    "EndPointBlank rejected this service's credential (HTTP 401); the " <>
      "client_id/client_secret is invalid or revoked and must be re-issued"
  end

  defp describe({:request_rejected, status}) do
    "EndPointBlank refused the token request (HTTP #{status})"
  end

  defp describe({:server_error, status}) do
    "EndPointBlank failed to issue a token (HTTP #{status})"
  end

  defp describe({:transport_error, reason}) do
    "EndPointBlank could not be reached (#{inspect(reason)})"
  end

  defp describe(nil), do: "no reason was recorded"

  defp describe(other), do: "unexpected failure (#{inspect(other)})"
end
