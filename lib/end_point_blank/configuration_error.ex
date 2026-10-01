defmodule EndPointBlank.ConfigurationError do
  @moduledoc """
  Raised when `client_id` or `client_secret` is not configured (nil or
  empty), so the SDK cannot authenticate to its intake (sc-1469):
  `EndPointBlank.Authorization.header!/1` and
  `EndPointBlank.Authorization.intake_header!/0` raise it, and
  `EndPointBlank.Authorization.header/1` and `intake_header/0` answer
  `{:error, :missing_credentials}` for the same case.

  Nothing is sent. Without this check every call to intake -- the token
  request, authorize, the endpoint update and the writers -- went out as
  `Basic` of `":"`, intake answered 401, and the token error read "re-issue
  the credential": a missing setting dressed up as a revoked credential.
  Retrying cannot help: set both with `EndPointBlank.configure/1` or
  `ENDPOINTBLANK_CLIENT_ID` / `ENDPOINTBLANK_CLIENT_SECRET`. The Ruby SDK
  raises its `EndPointBlank::ConfigurationError` for the same case, with the
  same message.

  `:missing` names the settings that were missing (`:client_id`,
  `:client_secret`), in that order; when it is not given the message names
  neither in particular.
  """

  defexception [:message, missing: []]

  @impl true
  def exception(opts) when is_list(opts) do
    missing = Keyword.get(opts, :missing, [])
    message = Keyword.get_lazy(opts, :message, fn -> message_for(missing) end)
    %__MODULE__{missing: missing, message: message}
  end

  defp message_for(missing) do
    names =
      case missing do
        [] -> "client_id or client_secret"
        keys -> Enum.map_join(keys, " and ", &to_string/1)
      end

    "EndPointBlank is missing #{names}: set it with EndPointBlank.configure/1 or " <>
      "ENDPOINTBLANK_CLIENT_ID / ENDPOINTBLANK_CLIENT_SECRET. The SDK cannot " <>
      "authenticate to its intake without both."
  end
end
