defmodule EndPointBlank.Management.Applications do
  @moduledoc """
  `/api/v1/applications`: your applications (API services), or, through
  `EndPointBlank.Management.for_managed_client/2`, a managed client's.

  An application is `%{"id", "name", "public", "organization_group_id",
  "synced_at", "inserted_at", "updated_at"}`. Its deployments are
  `EndPointBlank.Management.ApplicationEnvironments`.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @doc "One page of applications. Options: `limit:`, `after:`."
  @spec list(Management.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, opts \\ []),
    do: Request.page(client, :managed, ["applications"], opts)

  @doc "Every application, a page at a time. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, opts \\ []),
    do: Request.stream(client, :managed, ["applications"], opts)

  @doc "One application."
  @spec get(Management.t(), String.t()) :: Management.result(map())
  def get(%Management{} = client, id),
    do: client |> Request.get(:managed, ["applications", id]) |> Request.data()

  @doc """
  Creates an application. `attrs`: `name` (required), `public`,
  `organization_group_id`. Options: `idempotency_key:`.
  """
  @spec create(Management.t(), map() | keyword(), keyword()) :: Management.result(map())
  def create(%Management{} = client, attrs, opts \\ []),
    do: client |> Request.post(:managed, ["applications"], attrs, opts) |> Request.data()

  @doc "Updates an application. `attrs`: `name`, `public`."
  @spec update(Management.t(), String.t(), map() | keyword()) :: Management.result(map())
  def update(%Management{} = client, id, attrs),
    do: client |> Request.patch(:managed, ["applications", id], attrs) |> Request.data()

  @doc """
  Deletes an application: `%{"id", "deleted" => true}`. Refused with
  `"has_dependents"` while grants or credentials depend on it.
  """
  @spec delete(Management.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, id),
    do: client |> Request.delete(:managed, ["applications", id]) |> Request.data()
end
