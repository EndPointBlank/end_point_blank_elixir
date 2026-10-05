defmodule EndPointBlank.Management.Error do
  @moduledoc """
  A management API call that did not succeed (sc-1504).

  Every `EndPointBlank.Management` call answers `{:error, %Error{}}` rather
  than raising; the `stream/…` functions raise it, since a stream cannot
  answer a tuple.

    * `:code` -- the API's stable `error.code`, a string, for programs to
      match on (`"not_found"`, `"validation_failed"`, `"plan_limit"`, ...).
      A code this SDK does not know yet is kept as sent: see `known_codes/0`.
      The SDK adds four of its own, for answers that never reached the API or
      did not come back in its error shape: `"transport_error"`,
      `"unexpected_response"`, `"invalid_request"` and
      `"not_available_for_managed_client"`.
    * `:message` -- for people; it may change.
    * `:details` -- field-level detail when the API sent any (for
      `"validation_failed"`, the invalid fields), otherwise `nil`.
    * `:status` -- the HTTP status, or `nil` when no answer arrived.
    * `:retry_after` -- the `Retry-After` header in seconds, when sent.
    * `:location` -- the `Location` header, when sent. A credential POST
      refused with `"idempotency_replay_unavailable"` carries the
      credential's path here.

  The management key is never part of an error, and neither is a request or
  response body other than the API's own error object.

      case EndPointBlank.Management.Clients.get(mgmt, id) do
        {:ok, client} -> client
        {:error, %Error{code: "not_found"}} -> nil
        {:error, %Error{code: "rate_limited", retry_after: seconds}} -> ...
      end
  """

  defexception [:code, :message, :details, :status, :retry_after, :location]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          details: term(),
          status: pos_integer() | nil,
          retry_after: non_neg_integer() | nil,
          location: String.t() | nil
        }

  # Every code the management API answers, with its HTTP status, as the API
  # docs list them (app_portal `AppPortalWeb.ManagementApi.ErrorCodes`).
  @known_codes %{
    "missing_key" => 401,
    "invalid_key" => 401,
    "runtime_credential_refused" => 401,
    "insufficient_scope" => 403,
    "audit_unavailable" => 503,
    "rate_limited" => 429,
    "plan_limit" => 402,
    "validation_failed" => 422,
    "not_found" => 404,
    "invalid_pagination" => 400,
    "invalid_filter" => 422,
    "invalid_idempotency_key" => 400,
    "idempotency_key_reused" => 422,
    "idempotency_request_in_progress" => 409,
    "idempotency_replay_unavailable" => 409,
    "bad_request" => 400,
    "internal_server_error" => 500,
    "has_dependents" => 422,
    "protected" => 422,
    "invalid_environment_base_urls" => 422,
    "api_package_assigned" => 422,
    "intake_sync_failed" => 422,
    "delete_refused" => 422,
    "intake_credential" => 409,
    "intake_rejected" => 422,
    "intake_unavailable" => 503,
    "invalid_contacts" => 422,
    "invalid_packages" => 422,
    "invalid_grants" => 422,
    "invalid_managed" => 422,
    "client_not_accepted" => 422,
    "client_accepted" => 422,
    "client_not_managed" => 422,
    "already_a_member" => 422,
    "managed_client_has_credentials" => 422,
    "api_package_not_found" => 422,
    "environment_not_found" => 422,
    "already_assigned" => 422,
    "nothing_published_in_environment" => 422,
    "application_not_found" => 422,
    "endpoint_not_found" => 422,
    "environment_not_in_application" => 422,
    "already_granted" => 422,
    "grant_revoked_concurrently" => 409,
    "return_to_not_registered" => 422
  }

  @replay_unavailable_message "The first request with this Idempotency-Key succeeded, but its " <>
                                "answer held a secret shown only once, so it cannot be " <>
                                "replayed. Do not retry it: get or list the credential to " <>
                                "see its current state, and rotate it if the secret was lost."

  @doc """
  The error codes the management API is documented to answer, mapped to their
  HTTP status. A code missing from this map can still arrive and is surfaced
  unchanged; never treat an unknown code as a bug.
  """
  @spec known_codes() :: %{String.t() => pos_integer()}
  def known_codes, do: @known_codes

  @doc "True when `code` is one the management API is documented to answer."
  @spec known_code?(term()) :: boolean()
  def known_code?(code), do: Map.has_key?(@known_codes, code)

  @impl true
  def message(%__MODULE__{code: code, message: message, status: nil}),
    do: "#{message} (#{code})"

  def message(%__MODULE__{code: code, message: message, status: status}),
    do: "#{message} (#{code}, HTTP #{status})"

  @doc false
  # Builds the error for a non-2xx answer. Only the API's own error object is
  # read from the body; anything else in it is left out.
  @spec from_response(Req.Response.t()) :: t()
  def from_response(%Req.Response{status: status, body: body} = response) do
    base = %__MODULE__{
      status: status,
      retry_after: retry_after(response),
      location: header(response, "location")
    }

    case body do
      %{"error" => %{"code" => code} = error} when is_binary(code) ->
        %{
          base
          | code: code,
            message: message_for(code, error["message"], status),
            details: error["details"]
        }

      _other ->
        %{
          base
          | code: "unexpected_response",
            message: "The management API answered HTTP #{status} without an error object."
        }
    end
  end

  @doc false
  # The request never got an answer. Only the exception's module and atom
  # reason are kept: the term itself can carry the request.
  @spec transport(term()) :: t()
  def transport(reason) do
    %__MODULE__{
      code: "transport_error",
      message:
        "The management API could not be reached: " <>
          EndPointBlank.Http.describe_error(reason) <> "."
    }
  end

  @doc false
  @spec invalid_request(String.t()) :: t()
  def invalid_request(message), do: %__MODULE__{code: "invalid_request", message: message}

  defp message_for("idempotency_replay_unavailable", _message, _status),
    do: @replay_unavailable_message

  defp message_for(_code, message, _status) when is_binary(message) and message != "",
    do: message

  defp message_for(code, _message, status),
    do: "The management API refused the request with #{code} (HTTP #{status})."

  defp retry_after(response) do
    with value when is_binary(value) <- header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds
    else
      _ -> nil
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
