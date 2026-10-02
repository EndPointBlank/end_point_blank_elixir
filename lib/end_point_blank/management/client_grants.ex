defmodule EndPointBlank.Management.ClientGrants do
  @moduledoc """
  `/api/v1/clients/:client_id/grants`: the grants a client holds from you
  directly (not through an API package), or is set up to get when it accepts.

  A grant is `%{"id", "client_organization_id", "target_application_id",
  "target_endpoint_id", "all_endpoints", "environment_id",
  "also_granted_by_api_package_ids", "synced_at", "status", "refusal",
  "inserted_at", "updated_at"}`.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @doc "One page of a client's direct grants. Options: `limit:`, `after:`."
  @spec list(Management.t(), String.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, client_id, opts \\ []),
    do: Request.page(client, :organization, ["clients", client_id, "grants"], opts)

  @doc "Every direct grant of a client. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, client_id, opts \\ []),
    do: Request.stream(client, :organization, ["clients", client_id, "grants"], opts)

  @doc """
  Grants a client one endpoint of your application, or all of them.
  `attrs`: `target_application_id` and `environment_id` (required),
  `target_endpoint_id` (omit for every endpoint). Options: `idempotency_key:`.
  """
  @spec create(Management.t(), String.t(), map() | keyword(), keyword()) ::
          Management.result(map())
  def create(%Management{} = client, client_id, attrs, opts \\ []) do
    client
    |> Request.post(:organization, ["clients", client_id, "grants"], attrs, opts)
    |> Request.data()
  end

  @doc """
  Revokes a direct grant: `%{"id", "deleted" => true,
  "still_granted_by_package"}`. When `"still_granted_by_package"` is true the
  client keeps the access through an API package.
  """
  @spec delete(Management.t(), String.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, client_id, id) do
    client
    |> Request.delete(:organization, ["clients", client_id, "grants", id])
    |> Request.data()
  end
end
