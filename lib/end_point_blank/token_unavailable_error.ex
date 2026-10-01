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

    * `:base_url` -- the URL a token was requested for, stripped to scheme,
      host, port and path by `EndPointBlank.OutboundUrl.strip/1`, or `nil`
      when there was no URL or it could not be parsed. Userinfo, query and
      fragment can carry a secret, and error reporters capture an exception's
      fields as well as its message, so they are not kept anywhere on the
      exception; the caller already has the URL it passed.
    * `:reason` -- a `t:EndPointBlank.Authorization.reason/0`, kept exactly as
      it was returned. Branch on it to decide whether to retry:
      `{:transport_error, _}`, `{:server_error, _}`, `:invalid_token` and
      `:token_cache_unavailable` may clear on their own;
      `:credential_rejected`, `{:request_rejected, _}`, `:missing_base_url`
      and `:invalid_base_url` will not. A mint that raised or threw is a
      `{:transport_error, _}` carrying what was raised.
    * `:status` -- the HTTP status intake answered the token request with,
      when there was one: `401` for `:credential_rejected`, the status carried
      by `{:request_rejected, status}` or `{:server_error, status}`, and `nil`
      for every other reason (no response, or no status to report).
    * `:message` -- says what failed, why, and that credentials are never
      sent to providers.

  The message is built from fixed phrases only, the same ones every
  EndPointBlank SDK uses. It never `inspect`s the reason and never repeats
  intake's response body, an exception's message or its module name: a
  transport error can carry request data, and this message is the kind of
  thing that ends up in a log line. The full term is still on `:reason` for a
  caller that needs it.
  """

  alias EndPointBlank.OutboundUrl

  @credentials_never_sent "EndPointBlank never sends this service's client_id/client_secret " <>
                            "to a provider, so there is no Basic-auth fallback and the call " <>
                            "must not be made without a token."

  @transport_error "intake could not be reached (timeout, connection refused or " <>
                     "retries exhausted); this may be transient"

  defexception [:base_url, :reason, :status, :message]

  @impl true
  def exception(opts) when is_list(opts) do
    base_url = Keyword.get(opts, :base_url)
    reason = Keyword.get(opts, :reason)

    stripped =
      case OutboundUrl.strip(base_url) do
        {:ok, url} -> url
        {:error, _} -> nil
      end

    %__MODULE__{
      base_url: stripped,
      reason: reason,
      status: status(reason),
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
    "Could not mint an EndPointBlank access token for #{url_text(base_url)}: " <>
      "#{describe(reason)}. #{@credentials_never_sent}"
  end

  @doc """
  The HTTP status intake answered the token request with for `reason`, or
  `nil` when there was none. The same value an exception carries as `:status`.
  """
  @spec status(term()) :: pos_integer() | nil
  def status(:credential_rejected), do: 401
  def status({:request_rejected, status}) when is_integer(status), do: status
  def status({:server_error, status}) when is_integer(status), do: status
  def status(_reason), do: nil

  # Never `inspect`ed. Anything that is not a non-empty string (the
  # `:missing_base_url` case) could be any term at all, so it is not written
  # out; a string is written only as `OutboundUrl.strip/1` leaves it.
  defp url_text(base_url) when is_binary(base_url) and base_url != "" do
    case OutboundUrl.strip(base_url) do
      {:ok, stripped} -> stripped
      {:error, _} -> "the requested URL (not shown: it could not be parsed)"
    end
  end

  defp url_text(_base_url), do: "(no URL)"

  defp describe(:missing_base_url) do
    "no URL was given to mint a token for (pass the URL you are about to call)"
  end

  defp describe(:invalid_base_url) do
    "the URL could not be parsed into a scheme and host, so no token was requested"
  end

  defp describe(:token_cache_unavailable) do
    "the access-token cache did not answer in time (EndPointBlank may be slow or down)"
  end

  defp describe(:invalid_token) do
    "the access-token cache answered without a usable token"
  end

  defp describe(:credential_rejected) do
    "intake rejected this application's client credential (HTTP 401); " <>
      "retrying cannot help -- re-issue the credential"
  end

  defp describe({:request_rejected, status}) when is_integer(status) do
    "intake refused the token request (HTTP #{status}); check the URL and " <>
      "that a grant covers the target"
  end

  defp describe({:server_error, status}) when is_integer(status) do
    "intake failed to issue a token (HTTP #{status}); this may be transient"
  end

  # An atom (`:timeout`) or an HTTP-stack exception is intake being out of
  # reach. Anything else here was raised or thrown by the mint itself
  # (`AccessTokens`' rescue), which says nothing about intake.
  defp describe({:transport_error, reason}) do
    if transport_failure?(reason),
      do: @transport_error,
      else: "the token request failed unexpectedly"
  end

  defp describe(_other), do: "the token request failed for an unknown reason"

  defp transport_failure?(reason) when is_atom(reason), do: true

  defp transport_failure?(%{__exception__: true, __struct__: module}) do
    String.starts_with?(Atom.to_string(module), ["Elixir.Req.", "Elixir.Mint.", "Elixir.Finch."])
  end

  defp transport_failure?(_reason), do: false
end
