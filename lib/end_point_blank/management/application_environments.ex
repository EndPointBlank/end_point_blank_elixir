defmodule EndPointBlank.Management.ApplicationEnvironments do
  @moduledoc """
  `/api/v1/applications/:application_id/environments`: where an application
  is deployed, one base URL per environment. Through
  `EndPointBlank.Management.for_managed_client/2`, a managed client's.

  An application environment is `%{"id", "application_id", "environment_id",
  "base_url", "synced_at", "inserted_at", "updated_at"}`. Its `"id"` is what
  `EndPointBlank.Management.Credentials.create/3` takes as
  `application_environment_id`.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @doc "One page of an application's environments. Options: `limit:`, `after:`."
  @spec list(Management.t(), String.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, application_id, opts \\ []),
    do: Request.page(client, :managed, ["applications", application_id, "environments"], opts)

  @doc "Every environment of an application. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, application_id, opts \\ []),
    do: Request.stream(client, :managed, ["applications", application_id, "environments"], opts)

  @doc """
  Deploys an application to one more environment. `attrs`: `environment_id`
  and `base_url` (required). Refused with `"validation_failed"` for an
  environment the application is already in (including those it was created
  with). Options: `idempotency_key:`.
  """
  @spec create(Management.t(), String.t(), map() | keyword(), keyword()) ::
          Management.result(map())
  def create(%Management{} = client, application_id, attrs, opts \\ []) do
    client
    |> Request.post(:managed, ["applications", application_id, "environments"], attrs, opts)
    |> Request.data()
  end

  @doc """
  Removes an application environment: `%{"id", "deleted" => true}`. Refused
  with `"has_dependents"` while grants or credentials depend on it.
  """
  @spec delete(Management.t(), String.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, application_id, id) do
    client
    |> Request.delete(:managed, ["applications", application_id, "environments", id])
    |> Request.data()
  end
end
