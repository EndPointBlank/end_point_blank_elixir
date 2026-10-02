defmodule EndPointBlank.Management.ApiPackages do
  @moduledoc """
  `/api/v1/api_packages`: your API packages, and what each one publishes.

  A package is `%{"id", "name", "organization_id", "inserted_at", "updated_at"}`.

  What a package publishes is a list of entries, each one endpoint of your
  application (or all its endpoints, when `"all_endpoints"` is true) in one
  environment: `%{"id", "api_package_id", "application_id", "endpoint_id",
  "all_endpoints", "endpoint" => %{"id", "path", "action"} | nil,
  "environment_id", "inserted_at"}`. Adding or removing one re-derives the
  grants of every client holding the package; both answer
  `%{data: entry, warnings: [warning]}`, where each warning
  (`"code" => "assignment_derives_nothing"`) names a client assignment that
  now gives its client nothing.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @doc "One page of your API packages. Options: `limit:`, `after:`."
  @spec list(Management.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, opts \\ []),
    do: Request.page(client, :organization, ["api_packages"], opts)

  @doc "Every API package, a page at a time. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, opts \\ []),
    do: Request.stream(client, :organization, ["api_packages"], opts)

  @doc "One API package."
  @spec get(Management.t(), String.t()) :: Management.result(map())
  def get(%Management{} = client, id),
    do: client |> Request.get(:organization, ["api_packages", id]) |> Request.data()

  @doc """
  Creates an API package. `attrs`: `name` (required). Options:
  `idempotency_key:`.
  """
  @spec create(Management.t(), map() | keyword(), keyword()) :: Management.result(map())
  def create(%Management{} = client, attrs, opts \\ []),
    do: client |> Request.post(:organization, ["api_packages"], attrs, opts) |> Request.data()

  @doc "Renames an API package. `attrs`: `name`."
  @spec update(Management.t(), String.t(), map() | keyword()) :: Management.result(map())
  def update(%Management{} = client, id, attrs),
    do: client |> Request.patch(:organization, ["api_packages", id], attrs) |> Request.data()

  @doc """
  Deletes an API package: `%{"id", "deleted" => true}`. Refused with
  `"api_package_assigned"` while a client holds it.
  """
  @spec delete(Management.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, id),
    do: client |> Request.delete(:organization, ["api_packages", id]) |> Request.data()

  @doc "One page of what package `id` publishes. Options: `limit:`, `after:`."
  @spec list_endpoints(Management.t(), String.t(), keyword()) :: Management.result(Page.t())
  def list_endpoints(%Management{} = client, id, opts \\ []),
    do: Request.page(client, :organization, ["api_packages", id, "endpoints"], opts)

  @doc "Everything package `id` publishes. Raises `EndPointBlank.Management.Error`."
  @spec stream_endpoints(Management.t(), String.t(), keyword()) :: Enumerable.t()
  def stream_endpoints(%Management{} = client, id, opts \\ []),
    do: Request.stream(client, :organization, ["api_packages", id, "endpoints"], opts)

  @doc """
  Adds an endpoint to package `id`. `attrs`: `application_id` and
  `environment_id` (required), `endpoint_id` (omit or `nil` for every endpoint
  of the application). Answers `%{data: entry, warnings: warnings}`.
  Options: `idempotency_key:`.
  """
  @spec add_endpoint(Management.t(), String.t(), map() | keyword(), keyword()) ::
          Management.result(%{data: map(), warnings: [map()]})
  def add_endpoint(%Management{} = client, id, attrs, opts \\ []) do
    client
    |> Request.post(:organization, ["api_packages", id, "endpoints"], attrs, opts)
    |> Request.data_with_warnings()
  end

  @doc """
  Removes entry `access_id` from package `id`. Answers
  `%{data: %{"id", "deleted" => true}, warnings: warnings}`.
  """
  @spec remove_endpoint(Management.t(), String.t(), String.t()) ::
          Management.result(%{data: map(), warnings: [map()]})
  def remove_endpoint(%Management{} = client, id, access_id) do
    client
    |> Request.delete(:organization, ["api_packages", id, "endpoints", access_id])
    |> Request.data_with_warnings()
  end
end
