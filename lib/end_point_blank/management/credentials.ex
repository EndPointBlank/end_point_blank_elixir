defmodule EndPointBlank.Management.Credentials do
  @moduledoc """
  `/api/v1/credentials`: runtime client credentials, the `client_id` and
  `client_secret` an application environment's SDK authenticates with.
  Through `EndPointBlank.Management.for_managed_client/2`, a managed client's.

  A credential is `%{"id", "client_id", "secret_last_4",
  "application_environment_id", "application_id", "environment",
  "previous_secret", "expired_at", "created_at", "updated_at"}`: metadata
  only. The secret itself,
  `"client_secret"`, is in the answer to `create/3` and `rotate/3` and
  nowhere else, ever: store it then. This module never logs it.

  If that answer is lost, a retry with the same `Idempotency-Key` is refused
  with `"idempotency_replay_unavailable"` (the API does not keep the secret to
  replay it). Get or list the credential to see where it stands, and rotate
  it for a new secret.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @filters [:application_environment_id]

  @doc """
  One page of credentials (metadata only). Options: `limit:`, `after:`,
  `application_environment_id:`.
  """
  @spec list(Management.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, opts \\ []),
    do: Request.page(client, :managed, ["credentials"], opts, @filters)

  @doc "Every credential, with `list/2`'s filter. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, opts \\ []),
    do: Request.stream(client, :managed, ["credentials"], opts, @filters)

  @doc "One credential (metadata only)."
  @spec get(Management.t(), String.t()) :: Management.result(map())
  def get(%Management{} = client, id),
    do: client |> Request.get(:managed, ["credentials", id]) |> Request.data()

  @doc """
  Issues a credential for an application environment. `attrs`:
  `application_environment_id` (required). The answer carries
  `"client_secret"`, shown this once. Options: `idempotency_key:`.
  """
  @spec create(Management.t(), map() | keyword(), keyword()) :: Management.result(map())
  def create(%Management{} = client, attrs, opts \\ []),
    do: client |> Request.post(:managed, ["credentials"], attrs, opts) |> Request.data()

  @doc """
  Issues a new secret for credential `id`; the old one keeps working for the
  grace window (`"previous_secret"`). The answer carries the new
  `"client_secret"`, shown this once. Options: `idempotency_key:`.
  """
  @spec rotate(Management.t(), String.t(), keyword()) :: Management.result(map())
  def rotate(%Management{} = client, id, opts \\ []) do
    client
    |> Request.post(:managed, ["credentials", id, "rotate"], nil, opts)
    |> Request.data()
  end

  @doc """
  Revokes credential `id`: `%{"id", "deleted" => true}`. Refused with
  `"delete_refused"` when intake revoked it but its record could not be
  removed: retry the call.
  """
  @spec delete(Management.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, id),
    do: client |> Request.delete(:managed, ["credentials", id]) |> Request.data()

  @doc "Same as `delete/2`."
  @spec revoke(Management.t(), String.t()) :: Management.result(map())
  def revoke(%Management{} = client, id), do: delete(client, id)
end
