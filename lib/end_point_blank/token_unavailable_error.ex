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
    * `:reason` -- a `t:EndPointBlank.Authorization.reason/0`, kept exactly as
      it was returned. Branch on it to decide whether to retry:
      `{:transport_error, _}`, `{:server_error, _}`, `:invalid_token` and
      `:token_cache_unavailable` may clear on their own;
      `:credential_rejected` and `{:request_rejected, _}` will not.
    * `:status` -- the HTTP status intake answered the token request with,
      when there was one: `401` for `:credential_rejected`, the status carried
      by `{:request_rejected, status}` or `{:server_error, status}`, and `nil`
      for every other reason (no response, or no status to report).
    * `:message` -- says what failed, why, and that credentials are never
      sent to providers.

  The message never `inspect`s the reason. A transport error can carry
  request data, and this message is the kind of thing that ends up in a log
  line, so only known shapes are described (a `Req.TransportError` or a bare
  atom reason such as `:timeout`); anything else reads "unexpected error".
  The full term is still on `:reason` for a caller that needs it.
  """

  @credentials_never_sent "EndPointBlank never sends this service's client_id/client_secret " <>
                            "to a provider, so there is no Basic-auth fallback and the call " <>
                            "must not be made without a token."

  defexception [:base_url, :reason, :status, :message]

  @impl true
  def exception(opts) when is_list(opts) do
    base_url = Keyword.get(opts, :base_url)
    reason = Keyword.get(opts, :reason)

    %__MODULE__{
      base_url: base_url,
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

  # The URL is written as-is, never `inspect`ed. Anything that is not a
  # non-empty string (the `:missing_base_url` case) could be any term at all,
  # so it is not written out either.
  # Scheme, host and path only. The caller controls `base_url`, and its
  # userinfo, query or fragment can carry a secret; the message is what reaches
  # logs and error reporting, so they are dropped here. The raw value stays on
  # `:base_url`.
  defp url_text(base_url) when is_binary(base_url) and base_url != "" do
    case URI.new(base_url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        "#{scheme}://#{bracket(host)}#{port_text(uri)}#{uri.path}"

      _ ->
        "the requested URL (not shown: it could not be parsed)"
    end
  end

  defp url_text(_base_url), do: "(no URL)"

  defp bracket(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  defp port_text(%URI{scheme: scheme, port: port}) do
    if port == nil or port == URI.default_port(scheme), do: "", else: ":#{port}"
  end

  defp describe(:missing_base_url) do
    "no URL was given to mint a token for (pass the URL you are about to call)"
  end

  defp describe(:token_cache_unavailable) do
    "the access-token cache did not answer in time (EndPointBlank may be slow or down)"
  end

  defp describe(:invalid_token) do
    "the access-token cache answered without a usable token"
  end

  defp describe(:credential_rejected) do
    "EndPointBlank rejected this service's credential (HTTP 401); the " <>
      "client_id/client_secret is invalid or revoked and must be re-issued"
  end

  defp describe({:request_rejected, status}) when is_integer(status) do
    "EndPointBlank refused the token request (HTTP #{status})"
  end

  defp describe({:server_error, status}) when is_integer(status) do
    "EndPointBlank failed to issue a token (HTTP #{status})"
  end

  defp describe({:transport_error, %Req.TransportError{reason: reason}}) when is_atom(reason) do
    "intake could not be reached (#{Atom.to_string(reason)})"
  end

  defp describe({:transport_error, reason}) when is_atom(reason) do
    "intake could not be reached (#{Atom.to_string(reason)})"
  end

  # Deliberately not `inspect`ed: an arbitrary transport error term can carry
  # request data, and secrets must never reach a log line.
  defp describe({:transport_error, _reason}) do
    "intake could not be reached (unexpected error)"
  end

  defp describe(nil), do: "no reason was recorded"

  # Not `inspect`ed either, for the same reason.
  defp describe(_other), do: "unexpected failure"
end
