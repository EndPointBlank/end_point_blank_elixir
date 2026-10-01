defmodule EndPointBlank.ConfigurationError do
  @moduledoc """
  Raised by `EndPointBlank.Authorization.header!/1` when `client_id` or
  `client_secret` is not configured (nil or empty), so no token can be
  requested (sc-1469). `EndPointBlank.Authorization.header/1` answers
  `{:error, :missing_credentials}` for the same case.

  Kept apart from `EndPointBlank.TokenUnavailableError` on purpose. Without
  this check the token request went out as `Basic` of `":"`, intake answered
  401, and the error read "re-issue the credential" -- a missing setting
  dressed up as a revoked credential. Nothing is sent, and retrying cannot
  help: set both with `EndPointBlank.configure/1` or `ENDPOINTBLANK_CLIENT_ID`
  / `ENDPOINTBLANK_CLIENT_SECRET`. The Ruby SDK raises its
  `EndPointBlank::ConfigurationError` for the same case.
  """

  @default_message "EndPointBlank is missing client_id or client_secret: set both with " <>
                     "EndPointBlank.configure/1 or ENDPOINTBLANK_CLIENT_ID / " <>
                     "ENDPOINTBLANK_CLIENT_SECRET. The SDK cannot authenticate to its " <>
                     "intake without both, so no token was requested."

  defexception message: @default_message
end
